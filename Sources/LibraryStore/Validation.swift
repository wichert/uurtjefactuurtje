import Foundation

public struct Violation: Equatable, Sendable {
    public enum Code: String, Sendable, CaseIterable {
        case metadata, duplicateID, project, task, hierarchy, siblingName
        case ownership, interval, overlap, timer, pending, allocation, warning
    }

    public let code: Code
    public let recordID: UUID?

    public init(_ code: Code, _ recordID: UUID? = nil) {
        self.code = code
        self.recordID = recordID
    }
}

public enum LibraryError: Error, Equatable, Sendable {
    case invalid([Violation])
}

public enum SnapshotValidator {
    public static func validate(_ snapshot: LibrarySnapshot, now: Int64? = nil) throws {
        let errors = violations(in: snapshot, now: now)
        if !errors.isEmpty { throw LibraryError.invalid(errors) }
    }

    public static func violations(in snapshot: LibrarySnapshot, now: Int64? = nil) -> [Violation] {
        violations(in: snapshot, now: now, includingBudgets: true)
    }

    // BudgetRules reuses structural checks without recursively validating its own output.
    static func violations(in snapshot: LibrarySnapshot, now: Int64?, includingBudgets: Bool) -> [Violation] {
        guard unique(snapshot.projects.map(\.id)), unique(snapshot.tasks.map(\.id)),
            unique(snapshot.entries.map(\.id)), unique(snapshot.pendingSleepIntervals.map(\.id))
        else {
            return [Violation(.duplicateID)]
        }
        var errors: [Violation] = []
        if snapshot.schemaVersion != 2 || snapshot.revision < 0 { errors.append(Violation(.metadata)) }
        let projects = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0) })
        let tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        let currencies = Set(Locale.commonISOCurrencyCodes)
        for project in snapshot.projects {
            if !validName(project.name) || project.hourlyRate.isNaN || project.hourlyRate < 0
                || !currencies.contains(project.currencyCode) {
                errors.append(Violation(.project, project.id))
            }
        }
        var children: [UUID: [UUID]] = [:]
        var siblings: [SiblingKey: [UUID]] = [:]
        for task in snapshot.tasks {
            if !validName(task.name) || projects[task.projectID] == nil
                || task.budgetMinutes.map({ $0 <= 0 }) == true {
                errors.append(Violation(.task, task.id))
            }
            siblings[
                SiblingKey(
                    project: task.projectID, parent: task.parentTaskID,
                    name: NameKey.make(task.name)), default: []
            ].append(task.id)
            if let parentID = task.parentTaskID {
                children[parentID, default: []].append(task.id)
                if parentID == task.id || tasks[parentID]?.projectID != task.projectID {
                    errors.append(Violation(.hierarchy, task.id))
                }
            }
        }
        for group in siblings.values where group.count > 1 {
            errors += group.map { Violation(.siblingName, $0) }
        }
        var finished = Set<UUID>()
        for task in snapshot.tasks where !finished.contains(task.id) {
            var path: [UUID] = []
            var positions: [UUID: Int] = [:]
            var cursor: UUID? = task.id
            while let id = cursor, let current = tasks[id], !finished.contains(id) {
                if let cycleStart = positions[id] {
                    errors += path[cycleStart...].map { Violation(.hierarchy, $0) }
                    break
                }
                positions[id] = path.count
                path.append(id)
                cursor = current.parentTaskID
            }
            finished.formUnion(path)
        }
        errors = ordered(errors)
        if errors.contains(where: { $0.code == .task || $0.code == .hierarchy }) { return errors }

        func isLeaf(_ id: UUID) -> Bool { tasks[id] != nil && children[id] == nil }
        for entry in snapshot.entries where !isLeaf(entry.taskID) {
            errors.append(Violation(.ownership, entry.id))
        }
        for pending in snapshot.pendingSleepIntervals where !isLeaf(pending.taskID) {
            errors.append(Violation(.ownership, pending.id))
        }
        var closed: [(entry: TimeEntry, interval: EntryInterval)] = []
        for entry in snapshot.entries {
            guard let end = entry.endAt else { continue }
            guard let interval = try? EntryInterval(startAt: entry.startAt, endAt: end) else {
                errors.append(Violation(.interval, entry.id))
                continue
            }
            closed.append((entry, interval))
            if let now, end > now { errors.append(Violation(.interval, entry.id)) }
        }
        closed.sort {
            $0.entry.startAt == $1.entry.startAt
                ? uuidKey($0.entry.id) < uuidKey($1.entry.id) : $0.entry.startAt < $1.entry.startAt
        }
        var furthestEnd: Int64?
        for row in closed {
            if let end = furthestEnd, row.interval.startAt < end {
                errors.append(Violation(.overlap, row.entry.id))
            }
            furthestEnd = max(furthestEnd ?? row.interval.endAt, row.interval.endAt)
        }
        let open = snapshot.entries.filter { $0.endAt == nil }
        if !open.isEmpty || snapshot.activeTimer != nil {
            if open.count == 1, let entry = open.first, let timer = snapshot.activeTimer,
                timer.entryID == entry.id {
                let prefix =
                    timer.checkpointAt == entry.startAt
                    ? nil
                    : try? EntryInterval(startAt: entry.startAt, endAt: timer.checkpointAt)
                let validCheckpoint = timer.checkpointAt == entry.startAt || prefix != nil
                let validProject = tasks[entry.taskID].flatMap { projects[$0.projectID] }?.isArchived == false
                if !validCheckpoint || !validProject { errors.append(Violation(.timer, entry.id)) }
            } else {
                errors.append(Violation(.timer))
            }
        }
        // Every open row reserves its tail, even when the timer singleton is malformed.
        for entry in open where closed.contains(where: { $0.interval.endAt > entry.startAt }) {
            errors.append(Violation(.overlap, entry.id))
        }
        let unknown = snapshot.pendingSleepIntervals.filter { $0.wakeAt == nil }
        if unknown.count > 1 || (!unknown.isEmpty && snapshot.activeTimer != nil) {
            errors.append(Violation(.pending))
        }
        for pending in snapshot.pendingSleepIntervals {
            if let wake = pending.wakeAt,
                (try? EntryInterval(startAt: pending.sleepAt, endAt: wake)) == nil {
                errors.append(Violation(.pending, pending.id))
            }
        }
        errors = ordered(errors)

        if includingBudgets && errors.isEmpty {
            do {
                for allocation in try BudgetRules.allocations(in: snapshot)
                where allocation.allocatedMinutes > Decimal(allocation.limitMinutes) {
                    errors.append(Violation(.allocation, allocation.taskID))
                }
                let totals = try BudgetRules.usage(in: snapshot)
                for task in snapshot.tasks
                where task.lastWarnedThreshold
                    != BudgetRules.band(
                        used: totals[task.id, default: 0], budget: task.budgetMinutes) {
                    errors.append(Violation(.warning, task.id))
                }
            } catch let LibraryError.invalid(violations) { errors += violations } catch {
                errors.append(Violation(.allocation))
            }
        }
        return ordered(errors)
    }

    private struct SiblingKey: Hashable {
        let project: UUID
        let parent: UUID?
        let name: String
    }

    private static func unique(_ ids: [UUID]) -> Bool { Set(ids).count == ids.count }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("\0") && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uuidKey(_ id: UUID?) -> String { id?.uuidString.lowercased() ?? "" }

    private static func ordered(_ errors: [Violation]) -> [Violation] {
        var grouped: [Violation.Code: Set<UUID>] = [:]
        var whole = Set<Violation.Code>()
        for error in errors {
            if let id = error.recordID { grouped[error.code, default: []].insert(id) } else { whole.insert(error.code) }
        }
        return Violation.Code.allCases.flatMap { code in
            (whole.contains(code) ? [Violation(code)] : [])
                + (grouped[code] ?? []).sorted { uuidKey($0) < uuidKey($1) }.map { Violation(code, $0) }
        }
    }
}
