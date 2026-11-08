import Foundation

public enum WallTimeResolution: Equatable, Sendable {
    case nonexistent
    case unique(Int64)
    case ambiguous(earlier: Int64, later: Int64, earlierOffset: Int, laterOffset: Int)
}

public enum CorrectionClock {
    public static func resolve(_ components: DateComponents, calendar: Calendar) -> WallTimeResolution {
        guard calendar.identifier == .gregorian,
              components.calendar == nil || components.calendar?.identifier == .gregorian,
              components.timeZone == nil || components.timeZone == calendar.timeZone,
              components.era == nil || components.era == 1,
              let year = components.year, (1...9999).contains(year),
              let month = components.month, (1...12).contains(month),
              let day = components.day, (1...31).contains(day),
              let hour = components.hour, (0...23).contains(hour),
              let minute = components.minute, (0...59).contains(minute),
              let second = components.second, (0...59).contains(second),
              components.nanosecond == nil || components.nanosecond == 0 else { return .nonexistent }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let fields: Set<Calendar.Component> = [.era, .year, .month, .day, .hour, .minute, .second]
        let requested = DateComponents(era: 1, year: year, month: month, day: day,
                                       hour: hour, minute: minute, second: second)
        guard let nominal = utc.date(from: requested), utc.dateComponents(fields, from: nominal) == requested else {
            return .nonexistent
        }
        // Collect actual offsets, not assumed one-hour DST increments, on both sides of transitions.
        let window = 3.0 * 86_400
        var offsets: Set<Int> = []
        for delta in stride(from: -window, through: window, by: 900.0) {
            offsets.insert(calendar.timeZone.secondsFromGMT(for: nominal.addingTimeInterval(delta)))
        }
        var cursor = nominal.addingTimeInterval(-window)
        let limit = nominal.addingTimeInterval(window)
        while let transition = calendar.timeZone.nextDaylightSavingTimeTransition(after: cursor), transition <= limit {
            offsets.insert(calendar.timeZone.secondsFromGMT(for: transition.addingTimeInterval(-1)))
            offsets.insert(calendar.timeZone.secondsFromGMT(for: transition))
            cursor = transition.addingTimeInterval(1)
        }
        let instants = Set(offsets.compactMap { offset -> Int64? in
            let candidate = nominal.addingTimeInterval(-Double(offset))
            guard calendar.dateComponents(fields, from: candidate) == requested else { return nil }
            return Int64(candidate.timeIntervalSince1970)
        }).sorted()
        switch instants.count {
        case 1: return .unique(instants[0])
        case 2:
            return .ambiguous(earlier: instants[0], later: instants[1],
                              earlierOffset: calendar.timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(instants[0]))),
                              laterOffset: calendar.timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(instants[1]))))
        default: return .nonexistent
        }
    }

    public static func offsetText(_ offset: Int) -> String {
        let seconds = offset.magnitude
        let prefix = String(format: "UTC%@%02llu:%02llu", offset < 0 ? "−" : "+", seconds / 3600, seconds / 60 % 60)
        return seconds % 60 == 0 ? prefix : prefix + String(format: ":%02llu", seconds % 60)
    }
}

public struct LocalCorrectionTime: Equatable, Sendable {
    public var components: DateComponents
    public var selectedInstant: Int64?
    public init(components: DateComponents, selectedInstant: Int64? = nil) {
        self.components = components
        self.selectedInstant = selectedInstant
    }
    public func resolve(calendar: Calendar) throws -> Int64 {
        switch CorrectionClock.resolve(components, calendar: calendar) {
        case .nonexistent: throw CorrectionError.invalidInterval
        case let .unique(instant):
            guard selectedInstant == nil || selectedInstant == instant else { throw CorrectionError.invalidInterval }
            return instant
        case let .ambiguous(earlier, later, _, _):
            guard let selectedInstant, selectedInstant == earlier || selectedInstant == later else {
                throw CorrectionError.invalidInterval
            }
            return selectedInstant
        }
    }
    public mutating func select(_ instant: Int64) { selectedInstant = instant }
}

public enum CorrectionDraft: Equatable, Sendable {
    case add(id: UUID, taskID: UUID, startAt: Int64, endAt: Int64)
    case edit(id: UUID, taskID: UUID, startAt: Int64, endAt: Int64)

    var entry: TimeEntry {
        switch self {
        case let .add(id, taskID, start, end), let .edit(id, taskID, start, end):
            return TimeEntry(id: id, taskID: taskID, startAt: start, endAt: end)
        }
    }
}

public struct CorrectionPath: Equatable, Sendable {
    public let projectID: UUID
    public let projectName: String
    public let taskIDs: [UUID]
    public let taskNames: [String]
    public var text: String { ([projectName] + taskNames).joined(separator: " / ") }
}

public enum AdjustmentKind: String, Equatable, Sendable { case trimStart, trimEnd, split, delete }

public struct EntryAdjustment: Equatable, Sendable {
    public let before: TimeEntry
    public let retained: [TimeEntry]
    public let kind: AdjustmentKind
    public let path: CorrectionPath
}

public struct CorrectionPreview: Equatable, Sendable {
    public let draft: CorrectionDraft
    public let source: TimeEntry?
    public let sourcePath: CorrectionPath?
    public let targetPath: CorrectionPath
    public let adjustments: [EntryAdjustment]
    public let runningConflict: TimeEntry?
    public let runningPath: CorrectionPath?
}

public struct DeletionPreview: Equatable, Sendable {
    public let entry: TimeEntry
    public let path: CorrectionPath
}

public struct CorrectionReceipt: Equatable, Sendable {
    public let before: [TimeEntry]
    public let after: [TimeEntry]
    public let originalProjectByTask: [UUID: UUID]
}

public enum CorrectionError: Error, Equatable, Sendable {
    case invalidInterval, futureEnd, missingEntry, unavailableTask, crossProjectMove
    case runningConflict, stalePreview, deletionChanged, undoUnavailable
}

public enum CorrectionPlanner {
    public static func path(for taskID: UUID, in state: LibrarySnapshot) -> CorrectionPath? {
        var tasks: [UUID: TaskRecord] = [:]
        for task in state.tasks {
            guard tasks.updateValue(task, forKey: task.id) == nil else { return nil }
        }
        guard let leaf = tasks[taskID],
              state.projects.filter({ $0.id == leaf.projectID }).count == 1,
              let project = state.projects.first(where: { $0.id == leaf.projectID }) else { return nil }
        var ids: [UUID] = [], names: [String] = [], seen: Set<UUID> = []
        var cursor: UUID? = taskID
        while let id = cursor {
            guard seen.insert(id).inserted, let task = tasks[id], task.projectID == project.id else { return nil }
            ids.append(id); names.append(task.name)
            cursor = task.parentTaskID
        }
        return CorrectionPath(projectID: project.id, projectName: project.name,
                              taskIDs: Array(ids.reversed()), taskNames: Array(names.reversed()))
    }

    static func ordered(_ entries: [TimeEntry]) -> [TimeEntry] {
        entries.sorted {
            if $0.startAt != $1.startAt { return $0.startAt < $1.startAt }
            if $0.endAt != $1.endAt { return ($0.endAt ?? .max) < ($1.endAt ?? .max) }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public static func preview(_ draft: CorrectionDraft, in state: LibrarySnapshot) throws -> CorrectionPreview {
        try SnapshotValidator.validate(state, now: nil)
        let proposed = draft.entry
        guard let end = proposed.endAt,
              let interval = try? EntryInterval(startAt: proposed.startAt, endAt: end) else {
            throw CorrectionError.invalidInterval
        }
        guard let target = path(for: proposed.taskID, in: state),
              !state.tasks.contains(where: { $0.parentTaskID == proposed.taskID }) else {
            throw CorrectionError.unavailableTask
        }
        let source: TimeEntry?
        switch draft {
        case .add:
            guard !state.entries.contains(where: { $0.id == proposed.id }) else { throw CorrectionError.stalePreview }
            source = nil
        case .edit:
            guard let existing = state.entries.first(where: { $0.id == proposed.id }) else { throw CorrectionError.missingEntry }
            guard existing.endAt != nil else { throw CorrectionError.runningConflict }
            guard path(for: existing.taskID, in: state)?.projectID == target.projectID else {
                throw CorrectionError.crossProjectMove
            }
            source = existing
        }
        var used = Set(state.entries.map(\.id))
        used.insert(proposed.id)
        var adjustments: [EntryAdjustment] = []
        var running: TimeEntry?
        for entry in ordered(state.entries) where entry.id != source?.id {
            guard let oldEnd = entry.endAt else {
                if entry.startAt < end { running = entry }
                continue
            }
            let old = try EntryInterval(startAt: entry.startAt, endAt: oldEnd)
            guard old.overlaps(interval) else { continue }
            guard let owner = path(for: entry.taskID, in: state) else { throw CorrectionError.unavailableTask }
            var retained: [TimeEntry] = []
            if entry.startAt < proposed.startAt {
                retained.append(TimeEntry(id: entry.id, taskID: entry.taskID, startAt: entry.startAt, endAt: proposed.startAt))
            }
            if oldEnd > end {
                var id = entry.id
                if !retained.isEmpty {
                    repeat { id = UUID() } while used.contains(id)
                    used.insert(id)
                }
                retained.append(TimeEntry(id: id, taskID: entry.taskID, startAt: end, endAt: oldEnd))
            }
            let kind: AdjustmentKind = retained.count == 2 ? .split : retained.isEmpty ? .delete
                : retained[0].startAt == entry.startAt ? .trimEnd : .trimStart
            adjustments.append(EntryAdjustment(before: entry, retained: retained, kind: kind, path: owner))
        }
        return CorrectionPreview(draft: draft, source: source,
                                 sourcePath: source.flatMap { path(for: $0.taskID, in: state) },
                                 targetPath: target, adjustments: adjustments, runningConflict: running,
                                 runningPath: running.flatMap { path(for: $0.taskID, in: state) })
    }

    public static func previewDeletion(entryID: UUID, in state: LibrarySnapshot) throws -> DeletionPreview {
        try SnapshotValidator.validate(state, now: nil)
        guard let entry = state.entries.first(where: { $0.id == entryID }) else { throw CorrectionError.missingEntry }
        guard entry.endAt != nil else { throw CorrectionError.runningConflict }
        guard let owner = path(for: entry.taskID, in: state) else { throw CorrectionError.unavailableTask }
        return DeletionPreview(entry: entry, path: owner)
    }
}

public enum CorrectionCommand: Sendable {
    case apply(CorrectionPreview)
    case delete(DeletionPreview)
    case undo
}

// Internal composition seam: callers own authorization, one transaction, and publication.
struct CorrectionMutation: Sendable {
    let before: [TimeEntry]
    let after: [TimeEntry]
    let originalProjectByTask: [UUID: UUID]

    var receipt: CorrectionReceipt {
        CorrectionReceipt(before: before, after: after, originalProjectByTask: originalProjectByTask)
    }

    static func recheck(_ shown: CorrectionPreview, in state: LibrarySnapshot, now: Int64) throws -> CorrectionMutation {
        let fresh: CorrectionPreview
        do { fresh = try CorrectionPlanner.preview(shown.draft, in: state) }
        catch { throw CorrectionError.stalePreview }
        guard fresh.adjustments.count == shown.adjustments.count else { throw CorrectionError.stalePreview }
        let normalized = zip(fresh.adjustments, shown.adjustments).map { current, displayed in
            EntryAdjustment(before: current.before,
                            retained: current.retained.enumerated().map { index, row in
                                let id = current.kind == .split && index == 1 && displayed.retained.count == 2
                                    ? displayed.retained[1].id : row.id
                                return TimeEntry(id: id, taskID: row.taskID, startAt: row.startAt, endAt: row.endAt)
                            }, kind: current.kind, path: current.path)
        }
        let evidence = CorrectionPreview(draft: fresh.draft, source: fresh.source, sourcePath: fresh.sourcePath,
                                         targetPath: fresh.targetPath, adjustments: normalized,
                                         runningConflict: fresh.runningConflict, runningPath: fresh.runningPath)
        guard evidence == shown else { throw CorrectionError.stalePreview }
        guard fresh.runningConflict == nil else { throw CorrectionError.runningConflict }
        guard let end = shown.draft.entry.endAt, end <= now else { throw CorrectionError.futureEnd }
        let before = CorrectionPlanner.ordered((shown.source.map { [$0] } ?? []) + shown.adjustments.map(\.before))
        let after = CorrectionPlanner.ordered(shown.adjustments.flatMap(\.retained) + [shown.draft.entry])
        let existing = Set(state.entries.map(\.id))
        let splitIDs = shown.adjustments.filter { $0.kind == .split }.map { $0.retained[1].id }
        guard Set(after.map(\.id)).count == after.count, Set(splitIDs).count == splitIDs.count,
              splitIDs.allSatisfy({ !existing.contains($0) && $0 != shown.draft.entry.id }) else {
            throw CorrectionError.stalePreview
        }
        return try make(before: before, after: after, in: state)
    }

    static func deletion(_ shown: DeletionPreview, in state: LibrarySnapshot) throws -> CorrectionMutation {
        guard let fresh = try? CorrectionPlanner.previewDeletion(entryID: shown.entry.id, in: state), fresh == shown else {
            throw CorrectionError.deletionChanged
        }
        return try make(before: [shown.entry], after: [], in: state)
    }

    private static func make(before: [TimeEntry], after: [TimeEntry], in state: LibrarySnapshot) throws -> CorrectionMutation {
        var owners: [UUID: UUID] = [:]
        for row in before {
            guard let path = CorrectionPlanner.path(for: row.taskID, in: state) else { throw CorrectionError.unavailableTask }
            owners[row.taskID] = path.projectID
        }
        return CorrectionMutation(before: before, after: after, originalProjectByTask: owners)
    }

    // Warning bands are derived by the common write tail; never restore old bands with entry Undo.
    static func undo(_ receipt: CorrectionReceipt, in state: LibrarySnapshot, now: Int64) throws -> CorrectionMutation {
        guard Set(receipt.before.map(\.id)).count == receipt.before.count,
              Set(receipt.after.map(\.id)).count == receipt.after.count,
              Set(state.entries.map(\.id)).count == state.entries.count else { throw CorrectionError.undoUnavailable }
        let entries = Dictionary(uniqueKeysWithValues: state.entries.map { ($0.id, $0) })
        let afterIDs = Set(receipt.after.map(\.id))
        guard receipt.after.allSatisfy({ entries[$0.id] == $0 }),
              receipt.before.allSatisfy({ afterIDs.contains($0.id) || entries[$0.id] == nil }) else {
            throw CorrectionError.undoUnavailable
        }
        for row in receipt.before {
            guard let end = row.endAt, end <= now,
                  (try? EntryInterval(startAt: row.startAt, endAt: end)) != nil,
                  let owner = CorrectionPlanner.path(for: row.taskID, in: state),
                  owner.projectID == receipt.originalProjectByTask[row.taskID],
                  !state.tasks.contains(where: { $0.parentTaskID == row.taskID }) else {
                throw CorrectionError.undoUnavailable
            }
        }
        let candidate = LibrarySnapshot(schemaVersion: state.schemaVersion, revision: state.revision,
                                        projects: state.projects, tasks: state.tasks,
                                        entries: state.entries.filter { !afterIDs.contains($0.id) } + receipt.before,
                                        activeTimer: state.activeTimer, pendingSleepIntervals: state.pendingSleepIntervals)
        guard SnapshotValidator.violations(in: candidate, now: nil).allSatisfy({ $0.code == .warning }) else {
            throw CorrectionError.undoUnavailable
        }
        return CorrectionMutation(before: receipt.after, after: receipt.before, originalProjectByTask: [:])
    }

    func apply(to db: isolated Storage) throws {
        func key(_ id: UUID) -> SQLValue { .text(id.uuidString.lowercased()) }
        for row in before {
            guard let end = row.endAt else { throw CorrectionError.runningConflict }
            try db.runCommand("DELETE FROM time_entries WHERE id=? AND task_id=? AND start_at=? AND end_at=?",
                              bindings: [key(row.id), key(row.taskID), .integer(row.startAt), .integer(end)], expectedChanges: 1)
        }
        for row in after {
            guard let end = row.endAt else { throw CorrectionError.invalidInterval }
            try db.runCommand("INSERT INTO time_entries(id,task_id,start_at,end_at) VALUES (?,?,?,?)",
                              bindings: [key(row.id), key(row.taskID), .integer(row.startAt), .integer(end)], expectedChanges: 1)
        }
    }
}

extension Library {
    func performCorrection(_ command: CorrectionCommand, receipt: CorrectionReceipt?,
                           expectedRevision: Int64, instant: Int64) async throws -> Committed<CorrectionReceipt?> {
        // Only proposed/restored ends are checked against now; unrelated saved history may be future after rollback.
        try await transact(expectedRevision: expectedRevision, validationNow: nil) { db, before in
            let mutation: CorrectionMutation
            let next: CorrectionReceipt?
            switch command {
            case let .apply(preview):
                mutation = try CorrectionMutation.recheck(preview, in: before, now: instant)
                next = mutation.receipt
            case let .delete(preview):
                mutation = try CorrectionMutation.deletion(preview, in: before)
                next = mutation.receipt
            case .undo:
                guard let receipt else { throw CorrectionError.undoUnavailable }
                mutation = try CorrectionMutation.undo(receipt, in: before, now: instant)
                next = nil
            }
            try mutation.apply(to: db)
            return next
        }
    }
}
