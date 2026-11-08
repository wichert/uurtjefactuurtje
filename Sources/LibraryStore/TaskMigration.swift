import Foundation

public struct TaskCreationRequest: Sendable {
    public let id: UUID
    public let projectID: UUID
    public let parentID: UUID?
    public let name: String
    public let confirmMigration: Bool
    public let start: Bool

    public init(id: UUID, projectID: UUID, parentID: UUID?, name: String,
                confirmMigration: Bool, start: Bool) {
        self.id = id
        self.projectID = projectID
        self.parentID = parentID
        self.name = name
        self.confirmMigration = confirmMigration
        self.start = start
    }
}

public struct TaskCreation: Sendable {
    public let snapshot: LibrarySnapshot
    public let genericID: UUID?
    public let movedEntryCount: Int
    public let movedPendingCount: Int
}

public enum MigrationUndoAvailability: Equatable, Sendable {
    case available(receiptID: UUID)
    case unavailable(reason: String)
}

struct MigrationResult: Sendable {
    let genericID: UUID?
    let entries: Int
    let pending: Int
}

private func key(_ id: UUID) -> SQLValue { .text(id.uuidString.lowercased()) }

func createMigratingTask(_ request: TaskCreationRequest, before: LibrarySnapshot,
                         db: isolated Storage, ownedTimerEntryID: UUID?, instant: Int64?,
                         newEntryID: UUID) throws -> MigrationResult {
    let task = try taskForInsertion(id: request.id, projectID: request.projectID,
                                    parentID: request.parentID, name: request.name, in: before)
    let entries = before.entries.filter { $0.taskID == request.parentID }
    let pending = before.pendingSleepIntervals.filter { $0.taskID == request.parentID }
    let migrate = request.parentID != nil && !before.tasks.contains { $0.parentTaskID == request.parentID }
        && (!entries.isEmpty || !pending.isEmpty)
    guard before.activeTimer == nil || before.activeTimer?.entryID == ownedTimerEntryID else {
        throw CommandError.recoveryRequired
    }
    guard before.pendingSleepIntervals.isEmpty || (!request.start && migrate && !pending.isEmpty) else {
        throw CommandError.recoveryRequired
    }
    if migrate && !request.confirmMigration { throw CommandError.migrationConfirmationRequired }
    if migrate && NameKey.make(task.name) == NameKey.make("Generic") { throw CommandError.genericNameConflict }
    let generic = migrate ? TaskRecord(id: UUID(), projectID: request.projectID,
                                       parentTaskID: request.parentID, name: "Generic") : nil
    let movedEntries = before.entries.map { entry in
        entry.taskID == request.parentID && migrate
            ? TimeEntry(id: entry.id, taskID: generic!.id, startAt: entry.startAt, endAt: entry.endAt) : entry
    }
    let movedPending = before.pendingSleepIntervals.map { interval in
        interval.taskID == request.parentID && migrate
            ? PendingSleepInterval(id: interval.id, taskID: generic!.id, sleepAt: interval.sleepAt, wakeAt: interval.wakeAt) : interval
    }
    let interim = LibrarySnapshot(schemaVersion: before.schemaVersion, revision: before.revision,
                                  projects: before.projects, tasks: before.tasks + (generic.map { [$0] } ?? []) + [task],
                                  entries: movedEntries, activeTimer: before.activeTimer, pendingSleepIntervals: movedPending)
    try SnapshotValidator.validate(interim)
    let transition = try instant.map { try TimerTransition.plan(before: interim, operation: .start(taskID: task.id),
                                                                  instant: $0, newEntryID: newEntryID) }
    if let generic {
        try db.runCommand("INSERT INTO tasks(id,project_id,parent_task_id,name) VALUES (?,?,?,?)",
                          bindings: [key(generic.id), key(generic.projectID), key(request.parentID!), .text(generic.name)], expectedChanges: 1)
        try db.runCommand("UPDATE time_entries SET task_id=? WHERE task_id=?",
                          bindings: [key(generic.id), key(request.parentID!)], expectedChanges: entries.count)
        try db.runCommand("UPDATE pending_sleep_intervals SET task_id=? WHERE task_id=?",
                          bindings: [key(generic.id), key(request.parentID!)], expectedChanges: pending.count)
    }
    try db.runCommand("INSERT INTO tasks(id,project_id,parent_task_id,name) VALUES (?,?,?,?)",
                      bindings: [key(task.id), key(task.projectID), task.parentTaskID.map(key) ?? .null, .text(task.name)], expectedChanges: 1)
    try transition?.apply(to: db)
    return MigrationResult(genericID: generic?.id, entries: migrate ? entries.count : 0, pending: migrate ? pending.count : 0)
}

struct MigrationReceipt: Sendable {
    let id = UUID()
    let projectID: UUID
    let parentID: UUID
    let genericID: UUID
    let requestedID: UUID
    let tasks: [UUID: TaskRecord]
    let entries: [UUID: TimeEntry]
    let pending: [UUID: PendingSleepInterval]
    let activeTimer: ActiveTimer?

    init(projectID: UUID, parentID: UUID, genericID: UUID, requestedID: UUID, snapshot: LibrarySnapshot) {
        self.projectID = projectID
        self.parentID = parentID
        self.genericID = genericID
        self.requestedID = requestedID
        let ids: Set<UUID> = [parentID, genericID, requestedID]
        tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.filter { ids.contains($0.id) || $0.parentTaskID.map(ids.contains) == true }.map { ($0.id, $0) })
        let capturedEntries = Dictionary(uniqueKeysWithValues: snapshot.entries.filter { ids.contains($0.taskID) }.map { ($0.id, $0) })
        entries = capturedEntries
        pending = Dictionary(uniqueKeysWithValues: snapshot.pendingSleepIntervals.filter { ids.contains($0.taskID) }.map { ($0.id, $0) })
        activeTimer = snapshot.activeTimer.flatMap { capturedEntries[$0.entryID] == nil ? nil : $0 }
    }

    func unavailable(in snapshot: LibrarySnapshot, ownedTimerEntryID: UUID?) -> String? {
        guard let project = snapshot.projects.first(where: { $0.id == projectID }), !project.isArchived else {
            return "Project is missing or archived"
        }
        let ids: Set<UUID> = [parentID, genericID, requestedID]
        let currentTasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.filter { ids.contains($0.id) || $0.parentTaskID.map(ids.contains) == true }.map { ($0.id, $0) })
        guard currentTasks == tasks,
              Set(snapshot.tasks.filter { $0.parentTaskID == parentID }.map(\.id)) == Set([genericID, requestedID]),
              !snapshot.tasks.contains(where: { $0.parentTaskID == genericID || $0.parentTaskID == requestedID }) else {
            return "Task hierarchy changed"
        }
        guard !snapshot.entries.contains(where: { $0.taskID == requestedID }),
              !snapshot.pendingSleepIntervals.contains(where: { $0.taskID == requestedID }) else {
            return "New task owns time or pending sleep"
        }
        let currentEntries = Dictionary(uniqueKeysWithValues: snapshot.entries.filter { ids.contains($0.taskID) || entries[$0.id] != nil }.map { ($0.id, $0) })
        let currentPending = Dictionary(uniqueKeysWithValues: snapshot.pendingSleepIntervals.filter { ids.contains($0.taskID) || pending[$0.id] != nil }.map { ($0.id, $0) })
        let currentTimer = snapshot.activeTimer.flatMap { currentEntries[$0.entryID] == nil ? nil : $0 }
        guard currentEntries == entries, currentPending == pending, currentTimer == activeTimer else {
            return "Time, sleep or timer changed"
        }
        guard snapshot.activeTimer == nil || snapshot.activeTimer?.entryID == ownedTimerEntryID else {
            return "Active timer requires review"
        }
        let inverse = LibrarySnapshot(schemaVersion: snapshot.schemaVersion, revision: snapshot.revision,
            projects: snapshot.projects, tasks: snapshot.tasks.filter { $0.id != genericID && $0.id != requestedID },
            entries: snapshot.entries.map { $0.taskID == genericID ? TimeEntry(id: $0.id, taskID: parentID, startAt: $0.startAt, endAt: $0.endAt) : $0 },
            activeTimer: snapshot.activeTimer,
            pendingSleepIntervals: snapshot.pendingSleepIntervals.map { $0.taskID == genericID ? PendingSleepInterval(id: $0.id, taskID: parentID, sleepAt: $0.sleepAt, wakeAt: $0.wakeAt) : $0 })
        guard (try? SnapshotValidator.validate(inverse)) != nil else { return "Undo would make the library invalid" }
        return nil
    }

    func undo(in db: isolated Storage, snapshot: LibrarySnapshot, ownedTimerEntryID: UUID?) throws {
        guard unavailable(in: snapshot, ownedTimerEntryID: ownedTimerEntryID) == nil else { throw CommandError.undoUnavailable }
        try db.runCommand("UPDATE time_entries SET task_id=? WHERE task_id=?", bindings: [key(parentID), key(genericID)],
                          expectedChanges: snapshot.entries.filter { $0.taskID == genericID }.count)
        try db.runCommand("UPDATE pending_sleep_intervals SET task_id=? WHERE task_id=?", bindings: [key(parentID), key(genericID)],
                          expectedChanges: snapshot.pendingSleepIntervals.filter { $0.taskID == genericID }.count)
        try db.runCommand("DELETE FROM tasks WHERE id=?", bindings: [key(requestedID)], expectedChanges: 1)
        try db.runCommand("DELETE FROM tasks WHERE id=?", bindings: [key(genericID)], expectedChanges: 1)
    }
}
