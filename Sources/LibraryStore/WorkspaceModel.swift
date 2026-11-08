import Foundation
import Observation

public enum WorkspaceAvailability: Equatable, Sendable {
    case closed, opening, ready, reviewRequired, blocked, closing
}

public enum WorkspaceIssue: Equatable, Sendable {
    case busy, unsafeLibrary, invalidStorage, unavailable, closed, revisionConflict, recoveryRequired
    case uncertainSave, command(CommandError), validation([Violation]), other(String)
}

public enum PreferenceError: Error, Equatable, Sendable {
    case invalidFirstWeekday(Int)
}

struct WorkspaceOperations: Sendable {
    var settings: @Sendable (Library) async throws -> LibrarySettings = { try await $0.settings() }
    var setFirstWeekday: @Sendable (Library, Int) async throws -> LibrarySettings = {
        try await $0.setFirstWeekday($1)
    }
    var open: @Sendable (URL) async throws -> Library = { try await Library.open(at: $0) }
    var snapshot: @Sendable (Library) async throws -> LibrarySnapshot = { try await $0.snapshot() }
    var perform: @Sendable (Library, WorkspaceCommand, Int64) async throws -> LibrarySnapshot = {
        try await $0.perform($1, expectedRevision: $2)
    }
    var performOwned: @Sendable (Library, WorkspaceCommand, Int64, UUID) async throws -> LibrarySnapshot = {
        try await $0.performOwned($1, expectedRevision: $2, ownedTimerEntryID: $3)
    }
    var performBudget: @Sendable (Library, WorkspaceCommand, Int64, UUID, Int64) async throws -> LibrarySnapshot = {
        try await $0.performOwned($1, expectedRevision: $2, ownedTimerEntryID: $3, checkpointAt: $4)
    }
    var createTask: @Sendable (Library, TaskCreationRequest, Int64, UUID?, Int64?) async throws -> TaskCreation = {
        try await $0.createTaskOwned($1, expectedRevision: $2, ownedTimerEntryID: $3, instant: $4)
    }
    var close: @Sendable (Library) async -> Void = { await $0.close() }
}

@MainActor @Observable public final class WorkspaceModel {
    public private(set) var firstWeekday: Int?
    public private(set) var snapshot: LibrarySnapshot?
    public private(set) var availability: WorkspaceAvailability = .closed
    public private(set) var isBusy = false
    public private(set) var issue: WorkspaceIssue?
    private var confirmedMigrationUndoAvailability: MigrationUndoAvailability = .unavailable(reason: "No migration to undo")
    public var migrationUndoAvailability: MigrationUndoAvailability {
        guard !closing, pending == 0, state == .ready || state == .reviewRequired else {
            return .unavailable(reason: "Workspace is busy or unavailable")
        }
        return confirmedMigrationUndoAvailability
    }

    private let directory: URL
    private let operations: WorkspaceOperations
    private var library: Library?
    private var state: WorkspaceAvailability = .closed
    private var closing = false
    private var pending = 0
    private var tail: Task<Void, Never>?

    public convenience init(directory: URL) {
        self.init(directory: directory, operations: WorkspaceOperations())
    }

    init(directory: URL, operations: WorkspaceOperations) {
        self.directory = directory
        self.operations = operations
    }

    public private(set) var budgetWarnings: [BudgetWarningBatch] = []

    public func dismissBudgetWarning(_ id: UUID) {
        budgetWarnings.removeAll { $0.id == id }
    }

    private func safeLiveEnd(in confirmed: LibrarySnapshot,
                             sample captured: (generation: UInt64, instant: Int64)? = nil) throws -> Int64? {
        guard state == .ready, !closing, !timerPaused,
              !confirmed.pendingSleepIntervals.contains(where: { $0.wakeAt == nil }),
              let active = confirmed.activeTimer, ownedTimerEntryID == active.entryID,
              !timerLifecycleGate.state().sleeping else { return nil }
        let sample: (generation: UInt64, instant: Int64)
        do { sample = try captured ?? timerLifecycleGate.sample(clock: timerClock) }
        catch TimerError.reviewRequired { return nil }
        let gate = timerLifecycleGate.state()
        guard !gate.sleeping, gate.generation == sample.generation,
              sample.instant >= active.checkpointAt else { return nil }
        return sample.instant
    }

    public func projectReport(_ projectID: UUID, period: ReportPeriod, calendar: Calendar,
                              firstWeekday: Int = 2) throws -> ProjectReport {
        guard let snapshot else { throw LibraryAccessError.unavailable }
        let sample = try timerLifecycleGate.sample(allowSleeping: true, clock: timerClock)
        let bounds = try ReportCalendar.bounds(for: period, now: sample.instant,
                                               calendar: calendar, firstWeekday: firstWeekday)
        return try ReportProjection.project(projectID, in: snapshot, bounds: bounds, calendar: calendar,
                                            liveEnd: safeLiveEnd(in: snapshot, sample: sample))
    }

    public func weeklyReport(containing: Int64, calendar: Calendar, firstWeekday: Int = 2,
                             includeArchived: Bool = false) throws -> WeeklyReport {
        guard let snapshot else { throw LibraryAccessError.unavailable }
        let sample = try timerLifecycleGate.sample(allowSleeping: true, clock: timerClock)
        return try ReportProjection.week(in: snapshot, containing: containing, calendar: calendar,
                                         firstWeekday: firstWeekday, includeArchived: includeArchived,
                                         liveEnd: safeLiveEnd(in: snapshot, sample: sample))
    }

    public func budgetUsage() throws -> [UUID: Decimal] {
        guard let snapshot else { throw LibraryAccessError.unavailable }
        return try BudgetRules.usage(in: snapshot, liveEnd: safeLiveEnd(in: snapshot))
    }

    public func timerElapsedSeconds() throws -> Int64? {
        guard let snapshot else { throw LibraryAccessError.unavailable }
        _ = try BudgetRules.usage(in: snapshot)
        guard let active = snapshot.activeTimer else { return nil }
        guard let entry = snapshot.entries.first(where: { $0.id == active.entryID }) else {
            throw TimerError.activeEntryChanged
        }
        let end = try safeLiveEnd(in: snapshot) ?? active.checkpointAt
        if end == entry.startAt { return 0 }
        return try EntryInterval(startAt: entry.startAt, endAt: end).durationSeconds
    }

    public let timerLifecycleGate = TimerLifecycleGate()
    private var ownedTimerEntryID: UUID?
    private var correctionReceipt: CorrectionReceipt?
    private var correctionWrite: @Sendable (Library, CorrectionCommand, CorrectionReceipt?, Int64, Int64)
        async throws -> Committed<CorrectionReceipt?> = {
            try await $0.performCorrection($1, receipt: $2, expectedRevision: $3, instant: $4)
        }
    private var timeReviewReceipt: TimeReviewReceipt?
    private var sleepContinuation: SleepContinuation?
    private var handledSleepGeneration: UInt64?
    private var sessionSleepFloor: UInt64 = 0
    private var timeReviewWrite: @Sendable (Library, TimeReviewCommand, TimeReviewReceipt?, Int64, Int64)
        async throws -> Committed<TimeReviewReceipt?> = {
            try await $0.performTimeReview($1, receipt: $2, expectedRevision: $3, instant: $4)
        }
    private var sleepObservationWrite: @Sendable (Library, SleepObservationCommand, Int64)
        async throws -> LibrarySnapshot = {
            try await $0.performSleepObservation($1, expectedRevision: $2)
        }
    private var timerPaused = false
    private var timerClock: @Sendable () throws -> Int64 = timerWallSecond
    private var timerWrite: @Sendable (Library, TimerCommand, Int64, Int64, UUID) async throws -> LibrarySnapshot = {
        try await $0.performTimer($1, expectedRevision: $2, instant: $3, newEntryID: $4)
    }
    private var intentSequence: UInt64 = 0
    private var adjacentTimer: (command: TimerCommand, generation: UInt64, sequence: UInt64,
                                token: UUID, task: Task<LibrarySnapshot, Error>)?
    private var pendingCheckpoint: (token: UUID, task: Task<LibrarySnapshot, Error>)?

    public var timerStatus: TimerStatus {
        guard let snapshot else { return .idle }
        guard !snapshot.pendingSleepIntervals.contains(where: { $0.wakeAt == nil }) else { return .reviewRequired }
        guard let active = snapshot.activeTimer else { return .idle }
        guard ownedTimerEntryID == active.entryID else { return .reviewRequired }
        if timerPaused || timerLifecycleGate.state().sleeping || state == .blocked {
            return .paused(entryID: active.entryID)
        }
        return .running(entryID: active.entryID)
    }

    // Internal deterministic test seams, never preferences.
    func configureTimer(clock: @escaping @Sendable () throws -> Int64,
                        write: (@Sendable (Library, TimerCommand, Int64, Int64, UUID) async throws -> LibrarySnapshot)? = nil) {
        timerClock = clock
        timerLifecycleGate.configureObservationClock(clock)
        if let write { timerWrite = write }
    }

    private func clearTimerSession() {
        timeReviewReceipt = nil
        sleepContinuation = nil
        handledSleepGeneration = nil
        sessionSleepFloor = timerLifecycleGate.state().generation
        correctionReceipt = nil
        ownedTimerEntryID = nil
        timerPaused = false
        adjacentTimer = nil
        pendingCheckpoint = nil
        budgetWarnings = []
        // The lifetime gate is deliberately not reset by reopen or an old completion.
    }

    public func enqueueTimer(_ command: TimerCommand) -> Task<LibrarySnapshot, Error> {
        guard !Task.isCancelled else { return rejected(CancellationError()) }
        guard !closing, state == .ready || state == .reviewRequired else {
            return rejected(LibraryAccessError.unavailable)
        }
        let generation = timerLifecycleGate.state().generation
        if let adjacentTimer, adjacentTimer.command == command,
           adjacentTimer.generation == generation, adjacentTimer.sequence == intentSequence {
            return Task { try await adjacentTimer.task.value }
        }
        if case .checkpoint = command, let pendingCheckpoint {
            // A dropped periodic tick is still an intent barrier for adjacency.
            intentSequence += 1
            adjacentTimer = nil
            return Task { try await pendingCheckpoint.task.value }
        }
        let token = UUID()
        let task: Task<LibrarySnapshot, Error> = enqueue {
            defer {
                if self.adjacentTimer?.token == token { self.adjacentTimer = nil }
                if self.pendingCheckpoint?.token == token { self.pendingCheckpoint = nil }
            }
            guard let library = self.library, let before = self.snapshot,
                  self.state == .ready || self.state == .reviewRequired else {
                throw LibraryAccessError.unavailable
            }
            guard before.activeTimer == nil || before.activeTimer?.entryID == self.ownedTimerEntryID else {
                throw TimerError.reviewRequired
            }
            let safeStop: Bool
            if case let .stopAtCheckpoint(expected) = command {
                guard expected == self.ownedTimerEntryID, expected == before.activeTimer?.entryID else {
                    throw TimerError.activeEntryChanged
                }
                safeStop = true
            } else { safeStop = false }
            let ordinaryStop: Bool
            if case .stop = command { ordinaryStop = true } else { ordinaryStop = false }
            guard safeStop || !self.timerPaused else { throw TimerError.reviewRequired }
            guard !before.pendingSleepIntervals.contains(where: { $0.wakeAt == nil }) || safeStop || ordinaryStop else {
                throw TimerError.reviewRequired
            }
            var attemptedWrite = false
            do {
                let sample = try self.timerLifecycleGate.sample(allowSleeping: safeStop, clock: self.timerClock)
                // A queued action cannot cross a sleep boundary even if another action reset it.
                guard sample.generation == generation else { throw TimerError.reviewRequired }
                let transition = try TimerTransition.plan(before: before, operation: command, instant: sample.instant)
                guard transition.changes else { return before }
                attemptedWrite = true
                let result = try await self.timerWrite(library, command, before.revision, sample.instant, UUID())
                if case .start = command { self.ownedTimerEntryID = result.activeTimer?.entryID }
                if result.activeTimer == nil { self.ownedTimerEntryID = nil }
                if safeStop, !result.pendingSleepIntervals.contains(where: { $0.wakeAt == nil }),
                   self.timerLifecycleGate.reset(generation: sample.generation) { self.timerPaused = false }
                // Publication never releases a sleep latch for a start/checkpoint/ordinary stop.
                self.setConfirmed(result)
                self.issue = nil
                return result
            } catch {
                if attemptedWrite || (error as? TimerError) == .clockRollback {
                    self.timerPaused = before.activeTimer != nil
                    self.sleepContinuation = nil
                }
                self.issue = self.issueFor(error)
                if let storage = error as? StorageError {
                    switch storage {
                    case .sqlite, .injectedFailure: break
                    case .revisionConflict:
                        do { self.setConfirmed(try await self.operations.snapshot(library), publishedMutation: false) }
                        catch { self.setState(.blocked) }
                    default: self.setState(.blocked)
                    }
                } else if !(error is TimerError) && !(error is LibraryError) && !(error is CommandError) {
                    self.setState(.blocked)
                }
                throw error
            }
        }
        adjacentTimer = (command, generation, intentSequence, token, task)
        if case .checkpoint = command { pendingCheckpoint = (token, task) }
        return Task { try await task.value }
    }


    private func setState(_ value: WorkspaceAvailability) {
        state = value
        if value == .blocked {
            correctionReceipt = nil
            timeReviewReceipt = nil
            sleepContinuation = nil
        }
        availability = closing ? .closing : value
    }

    private func setConfirmed(_ value: LibrarySnapshot, publishedMutation: Bool = true) {
        if publishedMutation, let before = snapshot, value.revision > before.revision {
            let previous = Dictionary(uniqueKeysWithValues: before.tasks.map { ($0.id, $0.lastWarnedThreshold) })
            let increases = value.tasks.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap { task in
                task.lastWarnedThreshold.rawValue > (previous[task.id] ?? .none).rawValue
                    ? BudgetWarning(taskID: task.id, threshold: task.lastWarnedThreshold) : nil
            }
            if !increases.isEmpty { budgetWarnings.append(BudgetWarningBatch(id: UUID(), warnings: increases)) }
        }
        snapshot = value
        if value.activeTimer?.entryID != ownedTimerEntryID { ownedTimerEntryID = nil }
        let owned = value.activeTimer == nil || value.activeTimer?.entryID == ownedTimerEntryID
        let unknown = value.pendingSleepIntervals.contains { $0.wakeAt == nil }
        setState(owned && !unknown && !(timerPaused && value.activeTimer != nil) ? .ready : .reviewRequired)
    }

    // The returned task owns accepted work independently of its caller.
    func enqueue<Value: Sendable>(_ operation: @escaping @MainActor () async throws -> Value) -> Task<Value, Error> {
        intentSequence += 1
        let previous = tail
        pending += 1
        isBusy = true
        let task = Task { @MainActor in
            if let previous { await previous.value }
            defer {
                pending -= 1
                isBusy = pending != 0
            }
            do {
                let result = try await operation()
                await refreshMigrationUndoAvailability()
                return result
            } catch {
                await refreshMigrationUndoAvailability()
                throw error
            }
        }
        tail = Task { @MainActor in _ = await task.result }
        return Task { try await task.value }
    }

    private func refreshMigrationUndoAvailability() async {
        guard let library, !closing, state == .ready || state == .reviewRequired else {
            confirmedMigrationUndoAvailability = .unavailable(reason: "Workspace is unavailable")
            return
        }
        do {
            confirmedMigrationUndoAvailability = try await library.migrationUndoAvailability(ownedTimerEntryID: ownedTimerEntryID)
        } catch {
            confirmedMigrationUndoAvailability = .unavailable(reason: "Library is unavailable")
            issue = issueFor(error)
            setState(.blocked)
        }
    }

    private func rejected<Value: Sendable>(_ error: any Error) -> Task<Value, Error> {
        Task { throw error }
    }

    public func enqueueOpen() -> Task<Void, Error> {
        guard !Task.isCancelled else { return rejected(CancellationError()) }
        guard !closing else { return rejected(LibraryAccessError.unavailable) }
        guard state == .closed || state == .blocked else { return rejected(LibraryAccessError.unavailable) }
        clearTimerSession()
        firstWeekday = nil
        setState(.opening)
        return enqueue {
            if let old = self.library {
                await self.operations.close(old)
                self.library = nil
            }
            do {
                let directory = self.directory
                let operations = self.operations
                let opened = try await Task.detached { try await operations.open(directory) }.value
                do {
                    let initial = try await operations.snapshot(opened)
                    let settings = try await self.operations.settings(opened)
                    guard (1...7).contains(settings.firstWeekday) else {
                        throw LibraryAccessError.invalidSettings("weekday must be 1...7")
                    }
                    self.library = opened
                    self.firstWeekday = settings.firstWeekday
                    self.setConfirmed(initial, publishedMutation: false)
                    self.issue = nil
                } catch {
                    await operations.close(opened)
                    throw error
                }
            } catch {
                self.issue = self.issueFor(error)
                self.setState(.blocked)
                throw error
            }
        }
    }

    public func open() async throws { try await enqueueOpen().value }

    public func enqueueSubmit(_ command: WorkspaceCommand, expectedRevision: Int64) -> Task<LibrarySnapshot, Error> {
        guard !Task.isCancelled else { return rejected(CancellationError()) }
        guard !closing else { return rejected(LibraryAccessError.unavailable) }
        guard state == .ready || state == .reviewRequired else {
            if state != .blocked { issue = state == .closed ? .closed : .unavailable }
            return rejected(LibraryAccessError.unavailable)
        }
        let acceptedGeneration = timerLifecycleGate.state().generation
        return enqueue {
            guard let library = self.library, self.state == .ready else {
                if self.state == .reviewRequired {
                    self.issue = .recoveryRequired
                    throw CommandError.recoveryRequired
                }
                self.issue = .unavailable
                throw LibraryAccessError.unavailable
            }
            var sampledWrite = false
            do {
                let result: LibrarySnapshot
                if let owned = self.ownedTimerEntryID, let before = self.snapshot,
                   before.activeTimer?.entryID == owned {
                    if command.changesBudget, !self.timerPaused, !self.timerLifecycleGate.state().sleeping {
                        let sample = try self.timerLifecycleGate.sample(clock: self.timerClock)
                        let gate = self.timerLifecycleGate.state()
                        guard sample.generation == acceptedGeneration, gate.generation == sample.generation,
                              !gate.sleeping else { throw TimerError.reviewRequired }
                        if let active = before.activeTimer, sample.instant < active.checkpointAt {
                            throw TimerError.clockRollback
                        }
                        sampledWrite = true
                        result = try await self.operations.performBudget(
                            library, command, expectedRevision, owned, sample.instant)
                    } else {
                        result = try await self.operations.performOwned(library, command, expectedRevision, owned)
                    }
                } else {
                    result = try await self.operations.perform(library, command, expectedRevision)
                }
                self.setConfirmed(result)
                self.issue = nil
                return result
            } catch let error as StorageError {
                if sampledWrite { self.timerPaused = self.snapshot?.activeTimer != nil }
                if case .revisionConflict = error {
                    do {
                        self.setConfirmed(try await self.operations.snapshot(library), publishedMutation: false)
                        self.issue = .revisionConflict
                    } catch {
                        self.issue = self.issueFor(error)
                        self.setState(.blocked)
                    }
                } else {
                    self.issue = self.issueFor(error)
                    switch error {
                    case .sqlite, .injectedFailure: break
                    default: self.setState(.blocked)
                    }
                }
                throw error
            } catch {
                if sampledWrite || (error as? TimerError) == .clockRollback {
                    self.timerPaused = self.snapshot?.activeTimer != nil
                }
                self.issue = self.issueFor(error)
                if !(error is CommandError) && !(error is LibraryError) && !(error is TimerError) {
                    self.setState(.blocked)
                }
                throw error
            }
        }
    }

    public func enqueueTaskCreation(_ request: TaskCreationRequest, expectedRevision: Int64) -> Task<TaskCreation, Error> {
        guard !Task.isCancelled else { return rejected(CancellationError()) }
        guard !closing, state == .ready || state == .reviewRequired else { return rejected(LibraryAccessError.unavailable) }
        let generation = timerLifecycleGate.state().generation
        return enqueue {
            guard let library = self.library, let before = self.snapshot,
                  self.state == .ready || self.state == .reviewRequired else { throw LibraryAccessError.unavailable }
            var instant: Int64?
            do {
                if request.start {
                    guard before.pendingSleepIntervals.isEmpty,
                          before.activeTimer == nil || before.activeTimer?.entryID == self.ownedTimerEntryID,
                          !self.timerPaused else { throw TimerError.reviewRequired }
                    let sample = try self.timerLifecycleGate.sample(clock: self.timerClock)
                    guard sample.generation == generation else { throw TimerError.reviewRequired }
                    instant = sample.instant
                }
                let result = try await self.operations.createTask(library, request, expectedRevision,
                                                                  self.ownedTimerEntryID, instant)
                if request.start { self.ownedTimerEntryID = result.snapshot.activeTimer?.entryID }
                self.setConfirmed(result.snapshot)
                self.issue = nil
                return result
            } catch {
                if request.start, (error is StorageError || error is LibraryAccessError || (error as? TimerError) == .clockRollback) {
                    self.timerPaused = before.activeTimer != nil
                }
                await self.handleMigrationError(error, library: library)
                throw error
            }
        }
    }

    public func enqueueMigrationUndo(receiptID: UUID) -> Task<LibrarySnapshot, Error> {
        guard !Task.isCancelled else { return rejected(CancellationError()) }
        guard !closing, state == .ready || state == .reviewRequired else { return rejected(LibraryAccessError.unavailable) }
        return enqueue {
            guard let library = self.library, self.state == .ready || self.state == .reviewRequired else {
                throw LibraryAccessError.unavailable
            }
            do {
                let result = try await library.undoTaskMigration(receiptID: receiptID, ownedTimerEntryID: self.ownedTimerEntryID)
                self.setConfirmed(result)
                self.issue = nil
                return result
            } catch {
                await self.handleMigrationError(error, library: library)
                throw error
            }
        }
    }

    private func handleMigrationError(_ error: any Error, library: Library) async {
        issue = issueFor(error)
        if let storage = error as? StorageError {
            switch storage {
            case .revisionConflict:
                do { setConfirmed(try await operations.snapshot(library), publishedMutation: false) }
                catch { issue = issueFor(error); setState(.blocked) }
            case .sqlite, .injectedFailure: break
            default: setState(.blocked)
            }
        } else if !(error is CommandError) && !(error is LibraryError) && !(error is TimerError) {
            setState(.blocked)
        }
    }

    public func submit(_ command: WorkspaceCommand, expectedRevision: Int64) async throws -> LibrarySnapshot {
        try await enqueueSubmit(command, expectedRevision: expectedRevision).value
    }

    // Accept synchronously so this intent shares ordering with commands and close.
    public func enqueueFirstWeekday(_ weekday: Int) -> Task<Void, Error> {
        guard !Task.isCancelled else { return rejected(CancellationError()) }
        guard (1...7).contains(weekday) else {
            return rejected(PreferenceError.invalidFirstWeekday(weekday))
        }
        guard !closing, state == .ready || state == .reviewRequired else {
            return rejected(LibraryAccessError.unavailable)
        }
        return enqueue {
            guard let library = self.library,
                  self.state == .ready || self.state == .reviewRequired else {
                throw LibraryAccessError.unavailable
            }
            do {
                let settings = try await self.operations.setFirstWeekday(library, weekday)
                guard (1...7).contains(settings.firstWeekday) else {
                    throw LibraryAccessError.invalidSettings("weekday must be 1...7")
                }
                self.firstWeekday = settings.firstWeekday
                self.issue = nil
            } catch {
                self.issue = self.issueFor(error)
                if error is LibraryAccessError { self.setState(.blocked) }
                throw error
            }
        }
    }

    public func setFirstWeekday(_ weekday: Int) async throws {
        try await enqueueFirstWeekday(weekday).value
    }

    public func enqueueClose() -> Task<Void, Never> {
        if closing {
            let previous = tail
            return Task { if let previous { await previous.value } }
        }
        closing = true
        availability = .closing
        let task: Task<Void, Error> = enqueue {
            if let library = self.library { await self.operations.close(library) }
            self.clearTimerSession()
            self.library = nil
            self.snapshot = nil
            self.firstWeekday = nil
            self.issue = nil
            self.state = .closed
            self.closing = false
            self.availability = .closed
        }
        return Task { _ = await task.result }
    }

    public func close() async { await enqueueClose().value }

    private func issueFor(_ error: any Error) -> WorkspaceIssue {
        if let error = error as? CommandError {
            return error == .recoveryRequired ? .recoveryRequired : .command(error)
        }
        if case let LibraryError.invalid(violations) = error { return .validation(violations) }
        if let error = error as? LibraryOpenError {
            switch error {
            case .busy: return .busy
            case .unsafeState: return .unsafeLibrary
            case .filesystem: return .other(String(describing: error))
            }
        }
        if let error = error as? LibraryAccessError {
            switch error {
            case .publicationIndeterminate: return .uncertainSave
            case .unavailable: return .unavailable
            case .invalidSettings: return .other(String(describing: error))
            }
        }
        if let error = error as? StorageError {
            switch error {
            case .revisionConflict: return .revisionConflict
            case .commitIndeterminate: return .uncertainSave
            case .unavailable: return .unavailable
            case .invalidStorage, .unsupportedSchema: return .invalidStorage
            default: return .other(String(describing: error))
            }
        }
        return .other(String(describing: error))
    }
}

extension WorkspaceModel {
    func configureCorrections(write: @escaping @Sendable (Library, CorrectionCommand, CorrectionReceipt?, Int64, Int64)
                              async throws -> Committed<CorrectionReceipt?>) {
        correctionWrite = write
    }

    public var canUndoCorrection: Bool {
        guard !closing, !isBusy, state == .ready, let state = snapshot, let receipt = correctionReceipt,
              let sample = try? timerLifecycleGate.correctionSample(in: state, ownedEntryID: ownedTimerEntryID,
                                                                    paused: timerPaused, clock: timerClock),
              (try? CorrectionMutation.undo(receipt, in: state, now: sample.instant)) != nil else { return false }
        let gate = timerLifecycleGate.state()
        return !gate.sleeping && gate.generation == sample.generation
    }

    public func enqueueCorrection(_ command: CorrectionCommand) -> Task<LibrarySnapshot, Error> {
        guard !Task.isCancelled else { return rejected(CancellationError()) }
        guard !closing, state == .ready || state == .reviewRequired else {
            return rejected(LibraryAccessError.unavailable)
        }
        let acceptedGeneration = timerLifecycleGate.state().generation
        // An accepted Undo must never consume a replacement receipt from an earlier queued correction.
        let acceptedReceipt = correctionReceipt
        return enqueue {
            guard let library = self.library, let before = self.snapshot,
                  self.state == .ready || self.state == .reviewRequired else { throw LibraryAccessError.unavailable }
            do {
                let sample = try self.timerLifecycleGate.correctionSample(in: before,
                    ownedEntryID: self.ownedTimerEntryID, paused: self.timerPaused, clock: self.timerClock)
                guard sample.generation == acceptedGeneration else { throw TimerError.reviewRequired }
                if case .undo = command {
                    guard let acceptedReceipt, self.correctionReceipt == acceptedReceipt else {
                        throw CorrectionError.undoUnavailable
                    }
                    _ = try CorrectionMutation.undo(acceptedReceipt, in: before, now: sample.instant)
                }
                let committed = try await self.correctionWrite(library, command, self.correctionReceipt,
                                                               before.revision, sample.instant)
                self.correctionReceipt = committed.value
                self.setConfirmed(committed.snapshot)
                self.issue = nil
                // Never reset the gate: sleep may have latched while publication was suspended.
                return committed.snapshot
            } catch {
                if (error as? TimerError) == .clockRollback { self.timerPaused = before.activeTimer != nil }
                self.issue = self.issueFor(error)
                if let storage = error as? StorageError {
                    switch storage {
                    case .sqlite, .injectedFailure: break
                    case .revisionConflict:
                        do { self.setConfirmed(try await self.operations.snapshot(library), publishedMutation: false) }
                        catch { self.setState(.blocked) }
                    default: self.setState(.blocked)
                    }
                } else if !(error is CorrectionError) && !(error is TimerError) && !(error is LibraryError) {
                    self.setState(.blocked)
                }
                throw error
            }
        }
    }
}

extension WorkspaceModel {
    func configureTimeReview(write: @escaping @Sendable (Library, TimeReviewCommand, TimeReviewReceipt?, Int64, Int64)
                             async throws -> Committed<TimeReviewReceipt?>) {
        timeReviewWrite = write
    }

    func configureSleepObservations(write: @escaping @Sendable (Library, SleepObservationCommand, Int64)
                                   async throws -> LibrarySnapshot) {
        sleepObservationWrite = write
    }

    private func reviewIsAuthorized(_ command: TimeReviewCommand, in before: LibrarySnapshot) throws {
        if case .resolveInterruption = command, let active = before.activeTimer,
           ownedTimerEntryID == active.entryID, !timerPaused { throw TimerError.reviewRequired }
    }

    private func acknowledgeReview(generation: UInt64, in result: LibrarySnapshot) {
        guard !result.pendingSleepIntervals.contains(where: { $0.wakeAt == nil }),
              result.activeTimer == nil || (result.activeTimer?.entryID == ownedTimerEntryID && !timerPaused),
              handledSleepGeneration == generation || generation <= sessionSleepFloor else { return }
        _ = timerLifecycleGate.reset(generation: generation)
    }

    public var canUndoTimeReview: Bool {
        guard !closing, !isBusy, state == .ready || state == .reviewRequired,
              let snapshot, let receipt = timeReviewReceipt,
              let sample = try? timerLifecycleGate.sample(allowSleeping: true, clock: timerClock),
              (try? TimeReviewMutation.undo(receipt, in: snapshot, now: sample.instant)) != nil else { return false }
        return timerLifecycleGate.state().generation == sample.generation
    }

    public func enqueueTimeReview(_ command: TimeReviewCommand) -> Task<LibrarySnapshot, Error> {
        guard !Task.isCancelled else { return rejected(CancellationError()) }
        guard !closing, state == .ready || state == .reviewRequired else { return rejected(LibraryAccessError.unavailable) }
        let acceptedGeneration = timerLifecycleGate.state().generation
        let acceptedReceipt = timeReviewReceipt
        return enqueue {
            guard let library = self.library, let before = self.snapshot,
                  self.state == .ready || self.state == .reviewRequired else { throw LibraryAccessError.unavailable }
            do {
                let sample = try self.timerLifecycleGate.sample(allowSleeping: true, clock: self.timerClock)
                guard sample.generation == acceptedGeneration else { throw TimerError.reviewRequired }
                try self.reviewIsAuthorized(command, in: before)
                if case .undo = command {
                    guard let acceptedReceipt, acceptedReceipt == self.timeReviewReceipt else { throw SleepError.undoUnavailable }
                }
                let committed = try await self.timeReviewWrite(library, command, self.timeReviewReceipt,
                                                               before.revision, sample.instant)
                // Set conservative restored provenance before the observable snapshot is exposed.
                if case .undo = command, acceptedReceipt?.active != nil {
                    self.ownedTimerEntryID = nil
                    self.timerPaused = true
                }
                if case .resolveInterruption = command {
                    self.ownedTimerEntryID = nil
                    self.timerPaused = false
                }
                self.sleepContinuation = nil
                self.timeReviewReceipt = committed.value
                self.acknowledgeReview(generation: sample.generation, in: committed.snapshot)
                self.setConfirmed(committed.snapshot)
                self.issue = nil
                return committed.snapshot
            } catch {
                await self.handleTimeReviewFailure(error, library: library)
                throw error
            }
        }
    }

    // Classify the existing owner's outcome; never retry a mutation or infer its durability.
    private func handleTimeReviewFailure(_ error: any Error, library: Library) async {
        issue = issueFor(error)
        sleepContinuation = nil
        if let storage = error as? StorageError {
            switch storage {
            case .sqlite, .injectedFailure: break
            case .revisionConflict:
                do { setConfirmed(try await operations.snapshot(library), publishedMutation: false) }
                catch { setState(.blocked) }
            default: setState(.blocked)
            }
        } else if !(error is SleepError) && !(error is CorrectionError) && !(error is TimerError)
                    && !(error is LibraryError) && !(error is CommandError) {
            setState(.blocked)
        }
    }

    public func enqueueSleepObservation(generation: UInt64) -> Task<Void, Never> {
        guard !closing else { return Task {} }
        let task: Task<Void, Error> = enqueue {
            guard self.state == .ready || self.state == .reviewRequired,
                  let library = self.library, let before = self.snapshot,
                  generation > self.sessionSleepFloor, self.handledSleepGeneration != generation,
                  self.timerLifecycleGate.state().generation == generation,
                  self.timerLifecycleGate.state().sleeping else { return }
            self.handledSleepGeneration = generation
            self.sleepContinuation = nil
            guard let boundary = self.timerLifecycleGate.observedSleep(generation: generation) else {
                self.timerPaused = before.activeTimer != nil
                self.issue = self.issueFor(TimerError.clockRollback)
                return
            }
            guard let active = before.activeTimer else {
                if !before.pendingSleepIntervals.contains(where: { $0.wakeAt == nil }) {
                    self.sleepContinuation = SleepContinuation(generation: generation, pending: nil)
                }
                return
            }
            guard self.ownedTimerEntryID == active.entryID, !self.timerPaused,
                  boundary >= active.checkpointAt else {
                self.timerPaused = true
                return
            }
            let pendingID = UUID()
            do {
                let result = try await self.sleepObservationWrite(library,
                    .sleep(entryID: active.entryID, boundary: boundary, pendingID: pendingID), before.revision)
                self.ownedTimerEntryID = nil
                self.timerPaused = false
                self.setConfirmed(result)
                self.issue = nil
                if self.timerLifecycleGate.state().generation == generation,
                   let pending = result.pendingSleepIntervals.first(where: { $0.id == pendingID }) {
                    self.sleepContinuation = SleepContinuation(generation: generation, pending: pending)
                }
            } catch {
                self.timerPaused = true
                await self.handleTimeReviewFailure(error, library: library)
            }
        }
        return Task { _ = await task.result }
    }

    public func enqueueWakeObservation(generation: UInt64, observedAt: Int64) -> Task<Void, Never> {
        guard !closing else { return Task {} }
        let task: Task<Void, Error> = enqueue {
            guard self.state == .ready || self.state == .reviewRequired,
                  let library = self.library, let before = self.snapshot,
                  let proof = self.sleepContinuation, proof.generation == generation,
                  generation > self.sessionSleepFloor,
                  self.timerLifecycleGate.state().generation == generation,
                  self.timerLifecycleGate.state().sleeping else { return }
            self.sleepContinuation = nil // Duplicate callbacks cannot replace the first supplied wake boundary.
            guard let pending = proof.pending else {
                guard before.activeTimer == nil,
                      !before.pendingSleepIntervals.contains(where: { $0.wakeAt == nil }),
                      let boundary = self.timerLifecycleGate.observedSleep(generation: generation),
                      observedAt >= boundary else { return }
                _ = self.timerLifecycleGate.reset(generation: generation)
                return
            }
            guard before.activeTimer == nil, before.pendingSleepIntervals.contains(pending),
                  observedAt >= pending.sleepAt else { return }
            do {
                let id = UUID()
                let result = try await self.sleepObservationWrite(library,
                    .wake(pending: pending, observedAt: observedAt, entryID: id), before.revision)
                self.ownedTimerEntryID = id
                self.timerPaused = false
                _ = self.timerLifecycleGate.reset(generation: generation)
                self.setConfirmed(result)
                self.issue = nil
            } catch {
                await self.handleTimeReviewFailure(error, library: library)
            }
        }
        return Task { _ = await task.result }
    }
}
