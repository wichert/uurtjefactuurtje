import Foundation

public enum WarningThreshold: Int64, Sendable, CaseIterable {
    case none = 0
    case eighty = 80
    case hundred = 100
}

public struct Project: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let hourlyRate: Decimal
    public let currencyCode: String
    public let isArchived: Bool

    public init(
        id: UUID, name: String, hourlyRate: Decimal, currencyCode: String,
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.hourlyRate = hourlyRate
        self.currencyCode = currencyCode
        self.isArchived = isArchived
    }
}

public struct TaskRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let parentTaskID: UUID?
    public let name: String
    public let budgetMinutes: Int64?
    public let lastWarnedThreshold: WarningThreshold

    public init(
        id: UUID, projectID: UUID, parentTaskID: UUID? = nil, name: String,
        budgetMinutes: Int64? = nil, lastWarnedThreshold: WarningThreshold = .none
    ) {
        self.id = id
        self.projectID = projectID
        self.parentTaskID = parentTaskID
        self.name = name
        self.budgetMinutes = budgetMinutes
        self.lastWarnedThreshold = lastWarnedThreshold
    }
}

public struct TimeEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let startAt: Int64
    public let endAt: Int64?

    public init(id: UUID, taskID: UUID, startAt: Int64, endAt: Int64?) {
        self.id = id
        self.taskID = taskID
        self.startAt = startAt
        self.endAt = endAt
    }
}

public struct ActiveTimer: Equatable, Sendable {
    public let entryID: UUID
    public let checkpointAt: Int64

    public init(entryID: UUID, checkpointAt: Int64) {
        self.entryID = entryID
        self.checkpointAt = checkpointAt
    }
}

public struct PendingSleepInterval: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let sleepAt: Int64
    public let wakeAt: Int64?

    public init(id: UUID, taskID: UUID, sleepAt: Int64, wakeAt: Int64?) {
        self.id = id
        self.taskID = taskID
        self.sleepAt = sleepAt
        self.wakeAt = wakeAt
    }
}

// Values can represent untrusted input; persistence validates the complete snapshot.
public struct LibrarySnapshot: Equatable, Sendable {
    public let schemaVersion: Int64
    public let revision: Int64
    public let projects: [Project]
    public let tasks: [TaskRecord]
    public let entries: [TimeEntry]
    public let activeTimer: ActiveTimer?
    public let pendingSleepIntervals: [PendingSleepInterval]

    public init(
        schemaVersion: Int64, revision: Int64, projects: [Project], tasks: [TaskRecord],
        entries: [TimeEntry], activeTimer: ActiveTimer?,
        pendingSleepIntervals: [PendingSleepInterval]
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.projects = projects
        self.tasks = tasks
        self.entries = entries
        self.activeTimer = activeTimer
        self.pendingSleepIntervals = pendingSleepIntervals
    }
}

public enum IntervalError: Error, Equatable, Sendable {
    case nonPositiveDuration
    case durationOverflow
}

public struct EntryInterval: Equatable, Sendable {
    public let startAt: Int64
    public let endAt: Int64
    public var durationSeconds: Int64 { endAt - startAt }

    public init(startAt: Int64, endAt: Int64) throws {
        guard endAt > startAt else { throw IntervalError.nonPositiveDuration }
        guard !endAt.subtractingReportingOverflow(startAt).overflow else {
            throw IntervalError.durationOverflow
        }
        self.startAt = startAt
        self.endAt = endAt
    }

    public func overlaps(_ other: EntryInterval) -> Bool {
        startAt < other.endAt && other.startAt < endAt
    }

    public func intersection(_ other: EntryInterval) -> EntryInterval? {
        guard overlaps(other) else { return nil }
        return try? EntryInterval(startAt: max(startAt, other.startAt), endAt: min(endAt, other.endAt))
    }
}

public enum NameKey {
    public static func make(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}

extension LibrarySnapshot {
    /// Editor review ignores checkpoint bookkeeping, never a changed record or timer identity.
    public func editorRelevantEquals(_ other: LibrarySnapshot) -> Bool {
        func reviewed(_ value: LibrarySnapshot) -> LibrarySnapshot {
            LibrarySnapshot(
                schemaVersion: value.schemaVersion, revision: 0,
                projects: value.projects,
                tasks: value.tasks.map {
                    TaskRecord(
                        id: $0.id, projectID: $0.projectID, parentTaskID: $0.parentTaskID,
                        name: $0.name, budgetMinutes: $0.budgetMinutes, lastWarnedThreshold: .none)
                }, entries: value.entries,
                activeTimer: value.activeTimer.map { ActiveTimer(entryID: $0.entryID, checkpointAt: 0) },
                pendingSleepIntervals: value.pendingSleepIntervals)
        }
        return reviewed(self) == reviewed(other)
    }
}
