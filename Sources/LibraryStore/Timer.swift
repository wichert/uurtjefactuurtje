import Foundation

public enum TimerCommand: Equatable, Sendable {
    case start(taskID: UUID)
    case stop(expectedEntryID: UUID?)
    case checkpoint
    case stopAtCheckpoint(expectedEntryID: UUID)
}

public enum TimerError: Error, Equatable, Sendable {
    case reviewRequired, missingTask, notALeaf, archivedProject
    case clockRollback, activeEntryChanged
}

public enum TimerStatus: Equatable, Sendable {
    case idle
    case running(entryID: UUID)
    case paused(entryID: UUID)
    case reviewRequired
}

public final class TimerLifecycleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var sleeping = false
    private var sleepBoundary: Int64?
    private var observationClock: @Sendable () throws -> Int64 = timerWallSecond

    func configureObservationClock(_ clock: @escaping @Sendable () throws -> Int64) {
        lock.lock()
        defer { lock.unlock() }
        observationClock = clock
    }

    func observedSleep(generation expected: UInt64) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        guard sleeping, generation == expected else { return nil }
        return sleepBoundary
    }

    public init() {}

    @discardableResult public func latchSleep() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        // Never wrap a token and accidentally authorize an ancient completion.
        precondition(generation < UInt64.max)
        generation += 1
        sleeping = true
        sleepBoundary = try? observationClock()
        return generation
    }

    func state() -> (generation: UInt64, sleeping: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (generation, sleeping)
    }

    func sample(allowSleeping: Bool = false, clock: @Sendable () throws -> Int64)
        throws -> (generation: UInt64, instant: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard allowSleeping || !sleeping else { throw TimerError.reviewRequired }
        return (generation, try clock())
    }

    @discardableResult func reset(generation expected: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expected else { return false }
        sleeping = false
        sleepBoundary = nil
        return true
    }
}

func timerWallSecond() throws -> Int64 {
    let seconds = floor(Date().timeIntervalSince1970)
    guard seconds.isFinite, seconds >= Double(Int64.min), seconds < Double(Int64.max) else {
        throw TimerError.clockRollback
    }
    return Int64(seconds)
}

// Planned once before DML; also usable in a caller's migration transaction.
struct TimerTransition: Sendable {
    let previous: TimeEntry?
    let replacement: TimeEntry?
    let checkpoint: Int64
    let changes: Bool

    static func plan(before: LibrarySnapshot, operation: TimerCommand, instant: Int64,
                     newEntryID: UUID = UUID()) throws -> TimerTransition {
        let active = before.activeTimer
        let current = active.flatMap { timer in before.entries.first { $0.id == timer.entryID && $0.endAt == nil } }
        guard active == nil || current != nil else { throw TimerError.activeEntryChanged }
        if before.pendingSleepIntervals.contains(where: { $0.wakeAt == nil }) {
            switch operation {
            case .stop, .stopAtCheckpoint: break
            case .start, .checkpoint: throw TimerError.reviewRequired
            }
        }
        if case let .stop(expected) = operation {
            guard expected == active?.entryID else { throw TimerError.activeEntryChanged }
        }
        if case let .stopAtCheckpoint(expected) = operation {
            guard expected == active?.entryID else { throw TimerError.activeEntryChanged }
        }
        if case let .start(taskID) = operation {
            guard let task = before.tasks.first(where: { $0.id == taskID }) else { throw TimerError.missingTask }
            guard !before.tasks.contains(where: { $0.parentTaskID == taskID }) else { throw TimerError.notALeaf }
            guard let project = before.projects.first(where: { $0.id == task.projectID }), !project.isArchived else {
                throw TimerError.archivedProject
            }
        }
        guard !before.entries.contains(where: { ($0.endAt ?? Int64.min) > instant }) else {
            throw TimerError.clockRollback
        }
        if let active, instant < active.checkpointAt { throw TimerError.clockRollback }
        let end: Int64
        if case .stopAtCheckpoint = operation { end = active?.checkpointAt ?? instant } else { end = instant }
        if let current, end > current.startAt {
            _ = try EntryInterval(startAt: current.startAt, endAt: end)
        }
        let unchanged = TimerTransition(previous: current, replacement: nil, checkpoint: end, changes: false)
        switch operation {
        case let .start(taskID):
            if current?.taskID == taskID { return unchanged }
            guard !before.entries.contains(where: { $0.id == newEntryID }) else { throw TimerError.activeEntryChanged }
            return TimerTransition(previous: current,
                                   replacement: TimeEntry(id: newEntryID, taskID: taskID, startAt: instant, endAt: nil),
                                   checkpoint: instant, changes: true)
        case .stop, .stopAtCheckpoint:
            return TimerTransition(previous: current, replacement: nil, checkpoint: end, changes: current != nil)
        case .checkpoint:
            guard let active else { return unchanged }
            return TimerTransition(previous: nil, replacement: nil, checkpoint: instant,
                                   changes: active.checkpointAt != instant)
        }
    }

    static func checkpoint(before: LibrarySnapshot, entryID: UUID, instant: Int64,
                           to db: isolated Storage) throws {
        guard before.activeTimer?.entryID == entryID else { throw TimerError.activeEntryChanged }
        let transition = try plan(before: before, operation: .checkpoint, instant: instant)
        try transition.apply(to: db)
    }

    func apply(to db: isolated Storage) throws {
        guard changes else { return }
        func key(_ id: UUID) -> SQLValue { .text(id.uuidString.lowercased()) }
        if previous == nil && replacement == nil {
            try db.runCommand("UPDATE active_timer SET checkpoint_at=? WHERE id=1",
                              bindings: [.integer(checkpoint)], expectedChanges: 1)
            return
        }
        if let previous {
            try db.runCommand("DELETE FROM active_timer WHERE id=1 AND entry_id=?",
                              bindings: [key(previous.id)], expectedChanges: 1)
            if previous.startAt == checkpoint {
                try db.runCommand("DELETE FROM time_entries WHERE id=? AND end_at IS NULL",
                                  bindings: [key(previous.id)], expectedChanges: 1)
            } else {
                try db.runCommand("UPDATE time_entries SET end_at=? WHERE id=? AND end_at IS NULL",
                                  bindings: [.integer(checkpoint), key(previous.id)], expectedChanges: 1)
            }
        }
        if let replacement {
            try db.runCommand("INSERT INTO time_entries(id,task_id,start_at,end_at) VALUES (?,?,?,NULL)",
                              bindings: [key(replacement.id), key(replacement.taskID), .integer(replacement.startAt)], expectedChanges: 1)
            try db.runCommand("INSERT INTO active_timer(id,entry_id,checkpoint_at) VALUES (1,?,?)",
                              bindings: [key(replacement.id), .integer(checkpoint)], expectedChanges: 1)
        }
    }
}

extension TimerLifecycleGate {
    func correctionSample(in state: LibrarySnapshot, ownedEntryID: UUID?, paused: Bool,
                          clock: @Sendable () throws -> Int64) throws -> (generation: UInt64, instant: Int64) {
        guard !paused, state.pendingSleepIntervals.isEmpty,
              state.activeTimer == nil || state.activeTimer?.entryID == ownedEntryID else {
            throw TimerError.reviewRequired
        }
        let sample = try sample(clock: clock)
        if let active = state.activeTimer, sample.instant < active.checkpointAt { throw TimerError.clockRollback }
        return sample
    }
}

extension Library {
    // Workspace performs no-op detection; a changed transition is rechecked under BEGIN IMMEDIATE.
    func performTimer(_ command: TimerCommand, expectedRevision: Int64, instant: Int64,
                      newEntryID: UUID) async throws -> LibrarySnapshot {
        try await transact(expectedRevision: expectedRevision, validationNow: instant) { db, before in
            let transition = try TimerTransition.plan(before: before, operation: command,
                                                       instant: instant, newEntryID: newEntryID)
            try transition.apply(to: db)
        }.snapshot
    }
}

// Ephemeral proof is issued only after the sleep transaction has published in this process.
struct SleepContinuation: Equatable, Sendable {
    let generation: UInt64
    let pending: PendingSleepInterval?
}

enum SleepObservationCommand: Sendable {
    case sleep(entryID: UUID, boundary: Int64, pendingID: UUID)
    case wake(pending: PendingSleepInterval, observedAt: Int64, entryID: UUID)
}

extension Library {
    func performSleepObservation(_ command: SleepObservationCommand,
                                 expectedRevision: Int64) async throws -> LibrarySnapshot {
        try await transact(expectedRevision: expectedRevision, validationNow: nil) { db, before in
            func key(_ id: UUID) -> SQLValue { .text(id.uuidString.lowercased()) }
            switch command {
            case let .sleep(entryID, boundary, pendingID):
                guard let active = before.activeTimer, active.entryID == entryID,
                      let entry = before.entries.first(where: { $0.id == entryID && $0.endAt == nil }),
                      boundary >= active.checkpointAt,
                      !before.pendingSleepIntervals.contains(where: { $0.wakeAt == nil }) else {
                    throw TimerError.reviewRequired
                }
                let transition = try TimerTransition.plan(before: before, operation: .stop(expectedEntryID: entryID),
                                                          instant: boundary)
                try transition.apply(to: db)
                try db.runCommand("INSERT INTO pending_sleep_intervals(id,task_id,sleep_at,wake_at) VALUES (?,?,?,NULL)",
                    bindings: [key(pendingID), key(entry.taskID), .integer(boundary)], expectedChanges: 1)
            case let .wake(pending, observedAt, entryID):
                guard before.pendingSleepIntervals.contains(pending), pending.wakeAt == nil,
                      before.activeTimer == nil, observedAt >= pending.sleepAt,
                      let task = before.tasks.first(where: { $0.id == pending.taskID }),
                      !before.tasks.contains(where: { $0.parentTaskID == task.id }),
                      before.projects.contains(where: { $0.id == task.projectID && !$0.isArchived }),
                      !before.entries.contains(where: { $0.id == entryID || $0.endAt == nil || ($0.endAt ?? .min) > observedAt }) else {
                    throw TimerError.reviewRequired
                }
                if observedAt == pending.sleepAt {
                    try db.runCommand("DELETE FROM pending_sleep_intervals WHERE id=? AND wake_at IS NULL",
                        bindings: [key(pending.id)], expectedChanges: 1)
                } else {
                    _ = try EntryInterval(startAt: pending.sleepAt, endAt: observedAt)
                    try db.runCommand("UPDATE pending_sleep_intervals SET wake_at=? WHERE id=? AND wake_at IS NULL",
                        bindings: [.integer(observedAt), key(pending.id)], expectedChanges: 1)
                }
                try db.runCommand("INSERT INTO time_entries(id,task_id,start_at,end_at) VALUES (?,?,?,NULL)",
                    bindings: [key(entryID), key(pending.taskID), .integer(observedAt)], expectedChanges: 1)
                try db.runCommand("INSERT INTO active_timer(id,entry_id,checkpoint_at) VALUES (1,?,?)",
                    bindings: [key(entryID), .integer(observedAt)], expectedChanges: 1)
            }
        }.snapshot
    }
}
