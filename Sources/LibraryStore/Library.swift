import Foundation

public enum LibraryOpenError: Error, Equatable, Sendable {
    case busy
    case unsafeState(String)
    case filesystem(String, Int32)
}

public enum LibraryAccessError: Error, Equatable, Sendable {
    case unavailable
    case publicationIndeterminate
    case invalidSettings(String)
}

public struct LibrarySettings: Equatable, Sendable {
    public let firstWeekday: Int
}

public actor Library {
    private let recovery: Recovery
    private let lease: LibraryLease
    private var storage: Storage?
    private var sessionURL: URL
    private var available = true
    private var closed = false
    private var closeRequested = false
    private var occupied = false
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []
    private var migrationReceipt: MigrationReceipt?

    private init(recovery: Recovery, lease: LibraryLease, storage: Storage, sessionURL: URL) {
        self.recovery = recovery
        self.lease = lease
        self.storage = storage
        self.sessionURL = sessionURL
    }

    public static func open(at directory: URL) async throws -> Library {
        try await open(at: directory, hooks: RecoveryHooks())
    }

    static func open(at directory: URL, hooks: RecoveryHooks) async throws -> Library {
        // An unstructured detached task finishes recovery even if its caller cancels.
        try await Task.detached {
            guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.contains("\0"),
                  !directory.pathComponents.contains("..") else {
                throw LibraryOpenError.unsafeState("expected absolute file URL")
            }
            let recovery = Recovery(root: directory, hooks: hooks)
            try recovery.files.ensureDirectory(directory)
            let lease = try LibraryLease(directory: directory)
            do {
                try recovery.files.syncDirectory(directory)
                try recovery.inspect()
                // Reject malformed preferences before any canonical database replacement.
                _ = try recovery.settings()
                try await recovery.recover()
                let session = try recovery.newSession()
                let storage = try Storage(privateDatabaseAt: session)
                do { _ = try await storage.snapshot() }
                catch { await storage.close(); throw error }
                return Library(recovery: recovery, lease: lease, storage: storage, sessionURL: session)
            } catch { lease.release(); throw error }
        }.value
    }

    private func acquire() async throws {
        guard !closeRequested else { throw LibraryAccessError.unavailable }
        try Task.checkCancellation()
        if !occupied { occupied = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            occupied = false
            closeDrain?.resume()
            closeDrain = nil
        } else { waiters.removeFirst().continuation.resume() }
    }

    private func currentStorage() throws -> Storage {
        guard available, !closed, let storage else { throw LibraryAccessError.unavailable }
        return storage
    }

    public func snapshot() async throws -> LibrarySnapshot {
        try await acquire()
        defer { release() }
        return try await currentStorage().snapshot()
    }

    public func settings() async throws -> LibrarySettings {
        try await acquire()
        defer { release() }
        _ = try currentStorage()
        return try recovery.settings()
    }

    @discardableResult
    public func setFirstWeekday(_ day: Int) async throws -> LibrarySettings {
        try await acquire()
        defer { release() }
        _ = try currentStorage()
        do { return try recovery.saveSettings(day) }
        catch LibraryAccessError.publicationIndeterminate {
            available = false
            migrationReceipt = nil
            throw LibraryAccessError.publicationIndeterminate
        }
    }

    func transact<Value: Sendable>(
        expectedRevision: Int64,
        validationNow: Int64? = nil,
        _ apply: @Sendable (isolated Storage, LibrarySnapshot) throws -> Value
    ) async throws -> Committed<Value> {
        try await acquire()
        defer { release() }
        return try await transactLocked(expectedRevision: expectedRevision, validationNow: validationNow, apply)
    }

    private func transactLocked<Value: Sendable>(
        expectedRevision: Int64, validationNow: Int64? = nil,
        _ apply: @Sendable (isolated Storage, LibrarySnapshot) throws -> Value
    ) async throws -> Committed<Value> {
        let activeStorage = try currentStorage()
        let committed: Committed<Value>
        do {
            committed = try await activeStorage.transact(expectedRevision: expectedRevision,
                                                         validationNow: validationNow, apply)
        } catch StorageError.commitIndeterminate {
            available = false
            migrationReceipt = nil
            throw StorageError.commitIndeterminate
        } catch StorageError.unavailable {
            available = false
            migrationReceipt = nil
            throw StorageError.unavailable
        }
        // Do not observe cancellation after private commit or replay its body.
        do {
            let hooks = recovery.hooks
            try await Task.detached { try hooks.io(.privateCommitted) }.value
            await activeStorage.close()
            storage = nil
            try await recovery.publish(from: sessionURL)
            sessionURL = try recovery.newSession()
            let reopened = try Storage(privateDatabaseAt: sessionURL)
            storage = reopened
            guard try await reopened.snapshot() == committed.snapshot else {
                throw LibraryOpenError.unsafeState("published snapshot differs from private commit")
            }
            try recovery.hooks.io(.sessionReopened)
            return committed
        } catch {
            available = false
            migrationReceipt = nil
            // Lease and recovery/session evidence stay owned until explicit close.
            throw LibraryAccessError.publicationIndeterminate
        }
    }

    public func createTask(_ request: TaskCreationRequest, expectedRevision: Int64) async throws -> TaskCreation {
        let instant = request.start ? try timerWallSecond() : nil
        return try await createTaskOwned(request, expectedRevision: expectedRevision, ownedTimerEntryID: nil, instant: instant)
    }

    func createTaskOwned(_ request: TaskCreationRequest, expectedRevision: Int64,
                         ownedTimerEntryID: UUID?, instant: Int64?,
                         checkpointAt: Int64? = nil) async throws -> TaskCreation {
        try await acquire()
        defer { release() }
        guard request.start == (instant != nil),
              checkpointAt == nil || (!request.start && request.budgetMinutes != nil) else {
            throw TimerError.reviewRequired
        }
        let committed = try await transactLocked(expectedRevision: expectedRevision,
                                                 validationNow: instant ?? checkpointAt) { db, before in
            try createMigratingTask(request, before: before, db: db,
                ownedTimerEntryID: ownedTimerEntryID, instant: instant,
                newEntryID: UUID(), checkpointAt: checkpointAt)
        }
        if let generic = committed.value.genericID, let parent = request.parentID {
            migrationReceipt = MigrationReceipt(projectID: request.projectID, parentID: parent, genericID: generic,
                                                requestedID: request.id, snapshot: committed.snapshot)
        }
        return TaskCreation(snapshot: committed.snapshot, genericID: committed.value.genericID,
                            movedEntryCount: committed.value.entries, movedPendingCount: committed.value.pending)
    }

    public func migrationUndoAvailability() async throws -> MigrationUndoAvailability {
        try await migrationUndoAvailability(ownedTimerEntryID: nil)
    }

    func migrationUndoAvailability(ownedTimerEntryID: UUID?) async throws -> MigrationUndoAvailability {
        try await acquire()
        defer { release() }
        let snapshot = try await currentStorage().snapshot()
        guard let receipt = migrationReceipt else { return .unavailable(reason: "No migration to undo") }
        if let reason = receipt.unavailable(in: snapshot, ownedTimerEntryID: ownedTimerEntryID) {
            return .unavailable(reason: reason)
        }
        return .available(receiptID: receipt.id)
    }

    public func undoTaskMigration(receiptID: UUID) async throws -> LibrarySnapshot {
        try await undoTaskMigration(receiptID: receiptID, ownedTimerEntryID: nil)
    }

    func undoTaskMigration(receiptID: UUID, ownedTimerEntryID: UUID?) async throws -> LibrarySnapshot {
        try await acquire()
        defer { release() }
        guard let receipt = migrationReceipt, receipt.id == receiptID else { throw CommandError.undoUnavailable }
        let current = try await currentStorage().snapshot()
        let result = try await transactLocked(expectedRevision: current.revision) { db, before in
            try receipt.undo(in: db, snapshot: before, ownedTimerEntryID: ownedTimerEntryID)
        }
        migrationReceipt = nil
        return result.snapshot
    }

    public func close() async {
        if closed { return }
        if closeRequested {
            // Join the same FIFO tail rather than releasing ownership twice.
            await withCheckedContinuation { continuation in
                if closed { continuation.resume(); return }
                closeJoiners.append(continuation)
            }
            return
        }
        closeRequested = true
        if occupied {
            await withCheckedContinuation { continuation in
                closeDrain = continuation
            }
        }
        if let storage { await storage.close() }
        storage = nil
        available = false
        migrationReceipt = nil
        closed = true
        lease.release()
        for continuation in closeJoiners { continuation.resume() }
        closeJoiners.removeAll()
    }

    // Internal deterministic scheduling seams for the FIFO tests.
    func waitForQueuedOperations(_ count: Int) async {
        while waiters.count < count { await Task.yield() }
    }

    func waitForCloseRequest() async {
        while !closeRequested { await Task.yield() }
    }

    private var closeDrain: CheckedContinuation<Void, Never>?
    private var closeJoiners: [CheckedContinuation<Void, Never>] = []

    deinit {
        let retainedStorage = storage
        let retainedLease = lease
        Task.detached {
            if let retainedStorage { await retainedStorage.close() }
            retainedLease.release()
        }
    }
}
