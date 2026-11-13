import Foundation
import LibraryStore

private struct TaskTotals {
    var values: [TrackRowID: Int64]
    let tasks: [UUID: TaskRecord]
    let bottomUp: [UUID]

    init(snapshot: LibrarySnapshot) throws {
        values = try Self.seed(snapshot)
        for task in snapshot.tasks { values[.task(task.id)] = 0 }
        tasks = try Self.taskIndex(snapshot, totals: values)
        bottomUp = try Self.bottomUpOrder(snapshot, tasks: tasks)
    }

    private static func seed(_ snapshot: LibrarySnapshot) throws -> [TrackRowID: Int64] {
        var totals: [TrackRowID: Int64] = [:]
        for project in snapshot.projects {
            guard totals.updateValue(0, forKey: .project(project.id)) == nil else {
                throw ReportError.invalidHierarchy
            }
        }
        return totals
    }

    private static func taskIndex(
        _ snapshot: LibrarySnapshot,
        totals: [TrackRowID: Int64]
    ) throws -> [UUID: TaskRecord] {
        var tasks: [UUID: TaskRecord] = [:]
        for task in snapshot.tasks {
            guard totals[.project(task.projectID)] != nil,
                tasks.updateValue(task, forKey: task.id) == nil
            else { throw ReportError.invalidHierarchy }
        }
        return tasks
    }

    private static func bottomUpOrder(
        _ snapshot: LibrarySnapshot,
        tasks: [UUID: TaskRecord]
    ) throws -> [UUID] {
        var remaining: [UUID: Int] = [:]
        for task in snapshot.tasks {
            if let parent = task.parentTaskID {
                guard let owner = tasks[parent], owner.projectID == task.projectID else {
                    throw ReportError.invalidHierarchy
                }
                remaining[parent, default: 0] += 1
            }
        }
        var bottomUp = snapshot.tasks.filter { remaining[$0.id] == nil }.map(\.id)
        var index = 0
        while index < bottomUp.count {
            if let parent = tasks[bottomUp[index]]?.parentTaskID {
                remaining[parent, default: 0] -= 1
                if remaining[parent] == 0 { bottomUp.append(parent) }
            }
            index += 1
        }
        guard bottomUp.count == snapshot.tasks.count else { throw ReportError.invalidHierarchy }
        return bottomUp
    }

    mutating func addEntries(
        _ entries: [TimeEntry], snapshot: LibrarySnapshot,
        liveEnd: Int64?
    ) throws {
        // remaining is now zeroed; keep structural leaf identity independently for entry checks.
        let parentIDs = Set(snapshot.tasks.compactMap(\.parentTaskID))
        var seenEntries = Set<UUID>()
        var foundActive = false
        for entry in entries {
            guard seenEntries.insert(entry.id).inserted,
                tasks[entry.taskID] != nil, !parentIDs.contains(entry.taskID)
            else {
                throw ReportError.invalidHierarchy
            }
            let end = try Self.entryEnd(entry, snapshot: snapshot, liveEnd: liveEnd, foundActive: &foundActive)
            let (seconds, overflow) = end.subtractingReportingOverflow(entry.startAt)
            guard !overflow, seconds >= 0, seconds != 0 || entry.endAt == nil else {
                throw ReportError.intervalOverflow
            }
            values[.task(entry.taskID)] = try Self.adding(values[.task(entry.taskID), default: 0], seconds)
        }
        guard (snapshot.activeTimer != nil) == foundActive else { throw ReportError.invalidActiveEntry }
    }

    private static func entryEnd(
        _ entry: TimeEntry, snapshot: LibrarySnapshot,
        liveEnd: Int64?, foundActive: inout Bool
    ) throws -> Int64 {
        if let closed = entry.endAt {
            guard entry.id != snapshot.activeTimer?.entryID else { throw ReportError.invalidActiveEntry }
            return closed
        }
        guard let active = snapshot.activeTimer, active.entryID == entry.id, !foundActive,
            active.checkpointAt >= entry.startAt,
            liveEnd == nil || liveEnd! >= active.checkpointAt
        else {
            throw ReportError.invalidActiveEntry
        }
        foundActive = true
        return liveEnd ?? active.checkpointAt
    }

    mutating func rollUp() throws {
        for id in bottomUp {
            guard let task = tasks[id] else { throw ReportError.invalidHierarchy }
            let destination: TrackRowID = task.parentTaskID.map { .task($0) } ?? .project(task.projectID)
            values[destination] = try Self.adding(values[destination, default: 0], values[.task(id), default: 0])
        }
    }

    private static func adding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw ReportError.intervalOverflow }
        return value
    }
}

enum TrackTotals {
    static func projectTaskTotals(in snapshot: LibrarySnapshot, liveEnd: Int64?) throws -> [TrackRowID: Int64] {
        var totals = try TaskTotals(snapshot: snapshot)
        try totals.addEntries(snapshot.entries, snapshot: snapshot, liveEnd: liveEnd)
        try totals.rollUp()
        return totals.values
    }

    static func todayEntries(in snapshot: LibrarySnapshot, now: Date, calendar: Calendar) -> [TimeEntry] {
        guard let day = calendar.dateInterval(of: .day, for: now) else { return [] }
        let lowerBound = Int64(day.start.timeIntervalSince1970)
        let upperBound = Int64(day.end.timeIntervalSince1970)
        return snapshot.entries.filter { entry in
            if let end = entry.endAt { return entry.startAt < upperBound && end > lowerBound }
            return includesOpen(entry, snapshot: snapshot, lowerBound: lowerBound, upperBound: upperBound)
        }.sorted {
            $0.startAt == $1.startAt ? $0.id.uuidString < $1.id.uuidString : $0.startAt < $1.startAt
        }
    }

    private static func includesOpen(
        _ entry: TimeEntry, snapshot: LibrarySnapshot,
        lowerBound: Int64, upperBound: Int64
    ) -> Bool {
        entry.startAt >= lowerBound && entry.startAt < upperBound
            || (snapshot.activeTimer?.entryID == entry.id
                && (snapshot.activeTimer?.checkpointAt ?? entry.startAt) > lowerBound
                && entry.startAt < upperBound)
    }
}
