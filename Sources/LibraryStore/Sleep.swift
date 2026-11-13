import Foundation

public enum SleepError: Error, Equatable, Sendable {
    case staleReview, missingEnd, invalidEnd, undoUnavailable
}

public struct SleepInclusion: Equatable, Sendable {
    public let pending: PendingSleepInterval
    public let path: CorrectionPath
    public let correction: CorrectionPreview
}

public struct SleepSkipPreview: Equatable, Sendable {
    public let pending: PendingSleepInterval
    public let path: CorrectionPath
}

public struct InterruptionReview: Equatable, Sendable {
    public let active: ActiveTimer
    public let entry: TimeEntry
    public let path: CorrectionPath
    public let requestedEnd: Int64?
    public let correction: CorrectionPreview?
}

public enum TimeReviewCommand: Sendable {
    case include(SleepInclusion)
    case skip(SleepSkipPreview)
    case resolveInterruption(InterruptionReview)
    case undo
}

struct TimeReviewReceipt: Equatable, Sendable {
    let entries: CorrectionReceipt
    let pending: PendingSleepInterval?
    let active: ActiveTimer?
}

public enum SleepPlanner {
    public static func skip(_ pending: PendingSleepInterval, in state: LibrarySnapshot) throws -> SleepSkipPreview {
        try SnapshotValidator.validate(state, now: nil)
        guard state.pendingSleepIntervals.contains(pending),
            let path = CorrectionPlanner.path(for: pending.taskID, in: state),
            !state.tasks.contains(where: { $0.parentTaskID == pending.taskID })
        else { throw SleepError.staleReview }
        return SleepSkipPreview(pending: pending, path: path)
    }

    public static func include(
        _ pending: PendingSleepInterval, endAt: Int64?,
        in state: LibrarySnapshot
    ) throws -> SleepInclusion {
        let skipped = try skip(pending, in: state)
        let end = try inclusionEnd(pending, selected: endAt)
        let correction = try CorrectionPlanner.preview(
            .add(
                id: UUID(), taskID: pending.taskID,
                startAt: pending.sleepAt, endAt: end), in: state)
        return SleepInclusion(pending: pending, path: skipped.path, correction: correction)
    }

    static func inclusionEnd(_ pending: PendingSleepInterval, selected: Int64?) throws -> Int64 {
        if let wake = pending.wakeAt, let selected, wake != selected { throw SleepError.invalidEnd }
        guard let end = pending.wakeAt ?? selected else { throw SleepError.missingEnd }
        guard (try? EntryInterval(startAt: pending.sleepAt, endAt: end)) != nil else { throw SleepError.invalidEnd }
        return end
    }

    // The editor passes the checkpoint explicitly for its default suggestion; nil means discard.
    public static func interruption(endAt: Int64?, in state: LibrarySnapshot) throws -> InterruptionReview {
        try SnapshotValidator.validate(state, now: nil)
        guard let active = state.activeTimer,
            let entry = state.entries.first(where: { $0.id == active.entryID && $0.endAt == nil }),
            let path = CorrectionPlanner.path(for: entry.taskID, in: state)
        else { throw SleepError.staleReview }
        if let endAt, endAt < entry.startAt { throw SleepError.invalidEnd }
        let correction: CorrectionPreview?
        if let endAt, endAt > entry.startAt {
            guard (try? EntryInterval(startAt: entry.startAt, endAt: endAt)) != nil else { throw SleepError.invalidEnd }
            correction = try CorrectionPlanner.preview(
                .add(
                    id: entry.id, taskID: entry.taskID,
                    startAt: entry.startAt, endAt: endAt), in: withoutInterruption(state, entryID: entry.id))
        } else {
            correction = nil
        }
        return InterruptionReview(active: active, entry: entry, path: path, requestedEnd: endAt, correction: correction)
    }

    static func withoutInterruption(_ state: LibrarySnapshot, entryID: UUID) throws -> LibrarySnapshot {
        let virtual = LibrarySnapshot(
            schemaVersion: state.schemaVersion, revision: state.revision,
            projects: state.projects, tasks: state.tasks, entries: state.entries.filter { $0.id != entryID },
            activeTimer: nil, pendingSleepIntervals: state.pendingSleepIntervals)
        // Removing the checkpoint prefix changes derived warning bands in this preview-only view.
        let totals = try BudgetRules.usage(in: virtual)
        let tasks = state.tasks.map {
            TaskRecord(
                id: $0.id, projectID: $0.projectID, parentTaskID: $0.parentTaskID, name: $0.name,
                budgetMinutes: $0.budgetMinutes,
                lastWarnedThreshold: BudgetRules.band(used: totals[$0.id, default: 0], budget: $0.budgetMinutes))
        }
        return LibrarySnapshot(
            schemaVersion: virtual.schemaVersion, revision: virtual.revision,
            projects: virtual.projects, tasks: tasks, entries: virtual.entries, activeTimer: nil,
            pendingSleepIntervals: virtual.pendingSleepIntervals)
    }
}

// A composition value, never a second transaction or a public authorization flag.
struct TimeReviewMutation: Sendable {
    let entries: CorrectionMutation
    let removePending: PendingSleepInterval?
    let restorePending: PendingSleepInterval?
    let removeActive: ActiveTimer?
    let restoreActive: ActiveTimer?

    static func plan(
        _ command: TimeReviewCommand, receipt: TimeReviewReceipt?, in state: LibrarySnapshot,
        now: Int64
    ) throws -> (mutation: TimeReviewMutation, receipt: TimeReviewReceipt?) {
        let mutation: CorrectionMutation
        let pending: PendingSleepInterval?
        let active: ActiveTimer?
        switch command {
        case .include(let shown):
            guard let fresh = try? SleepPlanner.skip(shown.pending, in: state), fresh.path == shown.path,
                case .add(_, let task, let start, let end) = shown.correction.draft,
                task == shown.pending.taskID, start == shown.pending.sleepAt,
                try SleepPlanner.inclusionEnd(
                    shown.pending,
                    selected: end) == end
            else { throw SleepError.staleReview }
            mutation = try CorrectionMutation.recheck(shown.correction, in: state, now: now)
            pending = shown.pending
            active = nil
        case .skip(let shown):
            guard let fresh = try? SleepPlanner.skip(shown.pending, in: state),
                fresh == shown
            else { throw SleepError.staleReview }
            mutation = CorrectionMutation(before: [], after: [], originalProjectByTask: [:])
            pending = shown.pending
            active = nil
        case .resolveInterruption(let shown):
            guard state.activeTimer == shown.active, state.entries.contains(shown.entry), shown.entry.endAt == nil,
                shown.active.entryID == shown.entry.id,
                CorrectionPlanner.path(
                    for: shown.entry.taskID,
                    in: state) == shown.path
            else { throw SleepError.staleReview }
            if let end = shown.requestedEnd, end < shown.entry.startAt { throw SleepError.invalidEnd }
            let closed: CorrectionMutation
            if let end = shown.requestedEnd, end > shown.entry.startAt {
                guard let correction = shown.correction,
                    case .add(let id, let task, let start, let selected) = correction.draft,
                    id == shown.entry.id, task == shown.entry.taskID, start == shown.entry.startAt,
                    selected == end
                else { throw SleepError.staleReview }
                closed = try CorrectionMutation.recheck(
                    correction,
                    in: SleepPlanner.withoutInterruption(state, entryID: shown.entry.id), now: now)
            } else {
                guard shown.correction == nil else { throw SleepError.staleReview }
                closed = CorrectionMutation(before: [], after: [], originalProjectByTask: [:])
            }
            var owners = closed.originalProjectByTask
            owners[shown.entry.taskID] = shown.path.projectID
            mutation = CorrectionMutation(
                before: CorrectionPlanner.ordered(closed.before + [shown.entry]),
                after: closed.after, originalProjectByTask: owners)
            pending = nil
            active = shown.active
        case .undo:
            guard let receipt else { throw SleepError.undoUnavailable }
            return (try undo(receipt, in: state, now: now), nil)
        }
        var owners = mutation.originalProjectByTask
        if let pending {
            guard
                let owner = CorrectionPlanner.path(
                    for: pending.taskID,
                    in: state)
            else { throw SleepError.staleReview }
            owners[pending.taskID] = owner.projectID
        }
        let receipt = TimeReviewReceipt(
            entries: CorrectionReceipt(
                before: mutation.before, after: mutation.after,
                originalProjectByTask: owners), pending: pending, active: active)
        return (
            TimeReviewMutation(
                entries: mutation, removePending: pending, restorePending: nil,
                removeActive: active, restoreActive: nil), receipt
        )
    }

    // Used verbatim by both the read-only availability projection and the transaction.
    static func undo(_ receipt: TimeReviewReceipt, in state: LibrarySnapshot, now: Int64) throws -> TimeReviewMutation {
        let before = receipt.entries.before
        let after = receipt.entries.after
        guard Set(before.map(\.id)).count == before.count, Set(after.map(\.id)).count == after.count,
            Set(state.entries.map(\.id)).count == state.entries.count
        else { throw SleepError.undoUnavailable }
        let current = Dictionary(uniqueKeysWithValues: state.entries.map { ($0.id, $0) })
        let afterIDs = Set(after.map(\.id))
        guard after.allSatisfy({ current[$0.id] == $0 }),
            before.allSatisfy({ afterIDs.contains($0.id) || current[$0.id] == nil }),
            receipt.pending.map({ pending in !state.pendingSleepIntervals.contains(where: { $0.id == pending.id }) })
                ?? true,
            receipt.active == nil || state.activeTimer == nil
        else { throw SleepError.undoUnavailable }
        let restoredTasks = Set(before.map(\.taskID) + (receipt.pending.map { [$0.taskID] } ?? []))
        for taskID in restoredTasks {
            guard let owner = CorrectionPlanner.path(for: taskID, in: state),
                owner.projectID == receipt.entries.originalProjectByTask[taskID],
                !state.tasks.contains(where: { $0.parentTaskID == taskID })
            else { throw SleepError.undoUnavailable }
        }
        for row in before {
            if let end = row.endAt {
                guard end <= now,
                    (try? EntryInterval(
                        startAt: row.startAt,
                        endAt: end)) != nil
                else { throw SleepError.undoUnavailable }
            } else {
                guard receipt.active?.entryID == row.id else { throw SleepError.undoUnavailable }
            }
        }
        let candidate = LibrarySnapshot(
            schemaVersion: state.schemaVersion, revision: state.revision,
            projects: state.projects, tasks: state.tasks,
            entries: state.entries.filter { !afterIDs.contains($0.id) } + before,
            activeTimer: receipt.active ?? state.activeTimer,
            pendingSleepIntervals: state.pendingSleepIntervals + (receipt.pending.map { [$0] } ?? []))
        guard SnapshotValidator.violations(in: candidate, now: nil).allSatisfy({ $0.code == .warning }) else {
            throw SleepError.undoUnavailable
        }
        return TimeReviewMutation(
            entries: CorrectionMutation(before: after, after: before, originalProjectByTask: [:]),
            removePending: nil, restorePending: receipt.pending, removeActive: nil, restoreActive: receipt.active)
    }

    func apply(to database: isolated Storage) throws {
        func key(_ id: UUID) -> SQLValue { .text(id.uuidString.lowercased()) }
        if let active = removeActive {
            try database.runCommand(
                "DELETE FROM active_timer WHERE id=1 AND entry_id=? AND checkpoint_at=?",
                bindings: [key(active.entryID), .integer(active.checkpointAt)], expectedChanges: 1)
        }
        for row in entries.before where row.endAt == nil {
            try database.runCommand(
                "DELETE FROM time_entries WHERE id=? AND task_id=? AND start_at=? AND end_at IS NULL",
                bindings: [key(row.id), key(row.taskID), .integer(row.startAt)], expectedChanges: 1)
        }
        let closed = CorrectionMutation(
            before: entries.before.filter { $0.endAt != nil },
            after: entries.after.filter { $0.endAt != nil }, originalProjectByTask: [:])
        try closed.apply(to: database)
        if let pending = removePending {
            try database.runCommand(
                "DELETE FROM pending_sleep_intervals WHERE id=? AND task_id=? AND sleep_at=? AND wake_at IS ?",
                bindings: [
                    key(pending.id), key(pending.taskID), .integer(pending.sleepAt),
                    pending.wakeAt.map(SQLValue.integer) ?? .null
                ], expectedChanges: 1)
        }
        if let pending = restorePending {
            try database.runCommand(
                "INSERT INTO pending_sleep_intervals(id,task_id,sleep_at,wake_at) VALUES (?,?,?,?)",
                bindings: [
                    key(pending.id), key(pending.taskID), .integer(pending.sleepAt),
                    pending.wakeAt.map(SQLValue.integer) ?? .null
                ], expectedChanges: 1)
        }
        for row in entries.after where row.endAt == nil {
            try database.runCommand(
                "INSERT INTO time_entries(id,task_id,start_at,end_at) VALUES (?,?,?,NULL)",
                bindings: [key(row.id), key(row.taskID), .integer(row.startAt)], expectedChanges: 1)
        }
        if let active = restoreActive {
            try database.runCommand(
                "INSERT INTO active_timer(id,entry_id,checkpoint_at) VALUES (1,?,?)",
                bindings: [key(active.entryID), .integer(active.checkpointAt)], expectedChanges: 1)
        }
    }
}

extension Library {
    func performTimeReview(
        _ command: TimeReviewCommand, receipt: TimeReviewReceipt?, expectedRevision: Int64,
        instant: Int64
    ) async throws -> Committed<TimeReviewReceipt?> {
        try await transact(expectedRevision: expectedRevision, validationNow: nil) { database, before in
            let planned = try TimeReviewMutation.plan(command, receipt: receipt, in: before, now: instant)
            try planned.mutation.apply(to: database)
            return planned.receipt
        }
    }
}
