import Foundation

public enum WorkspaceCommand: Sendable {
    case createProject(id: UUID, name: String, rate: Decimal, currency: String)
    case updateProject(id: UUID, name: String, rate: Decimal, currency: String,
                       confirmedPreviousCurrency: String?)
    case setArchived(id: UUID, archived: Bool)
    case createTask(id: UUID, projectID: UUID, parentID: UUID?, name: String, budgetSeconds: Int64? = nil)
    case renameTask(id: UUID, name: String)
    case editTask(id: UUID, name: String, budgetSeconds: Int64?)

    var changesBudget: Bool {
        switch self {
        case .createTask, .editTask: true
        default: false
        }
    }
}

public enum CommandError: Error, Equatable, Sendable {
    case missingRecord, alreadyExists, archivedProject, migrationRequired, recoveryRequired
    case migrationConfirmationRequired, genericNameConflict, undoUnavailable
    case currencyConfirmationRequired(String), currencyChanged
    case budgetAllocation(taskID: UUID, allowance: BudgetAllowance)
}

func taskForInsertion(id: UUID, projectID: UUID, parentID: UUID?, name: String,
                      in snapshot: LibrarySnapshot) throws -> TaskRecord {
    guard !snapshot.tasks.contains(where: { $0.id == id }) else { throw CommandError.alreadyExists }
    guard let project = snapshot.projects.first(where: { $0.id == projectID }) else { throw CommandError.missingRecord }
    guard !project.isArchived else { throw CommandError.archivedProject }
    if let parentID, !snapshot.tasks.contains(where: { $0.id == parentID && $0.projectID == projectID }) {
        throw CommandError.missingRecord
    }
    return TaskRecord(id: id, projectID: projectID, parentTaskID: parentID,
                      name: name.trimmingCharacters(in: .whitespacesAndNewlines))
}

extension Library {
    public func perform(_ command: WorkspaceCommand, expectedRevision: Int64) async throws -> LibrarySnapshot {
        try await performOwned(command, expectedRevision: expectedRevision, ownedTimerEntryID: nil)
    }

    func performOwned(_ command: WorkspaceCommand, expectedRevision: Int64,
                      ownedTimerEntryID: UUID?, checkpointAt: Int64? = nil) async throws -> LibrarySnapshot {
        let committed = try await transact(expectedRevision: expectedRevision, validationNow: checkpointAt) { db, before in
            if case let .createTask(_, projectID, parentID?, _, _) = command,
               before.tasks.contains(where: { $0.id == parentID && $0.projectID == projectID }),
               before.pendingSleepIntervals.contains(where: { $0.taskID == parentID }) {
                throw CommandError.migrationRequired
            }
            guard before.pendingSleepIntervals.isEmpty,
                  before.activeTimer == nil || before.activeTimer?.entryID == ownedTimerEntryID else {
                throw CommandError.recoveryRequired
            }
            if let checkpointAt {
                guard command.changesBudget, let ownedTimerEntryID,
                      before.activeTimer?.entryID == ownedTimerEntryID else { throw TimerError.activeEntryChanged }
                try TimerTransition.checkpoint(before: before, entryID: ownedTimerEntryID,
                                               instant: checkpointAt, to: db)
            }
            func key(_ id: UUID) -> SQLValue { .text(id.uuidString.lowercased()) }
            func name(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
            func validate(projects: [Project]? = nil, tasks: [TaskRecord]? = nil) throws {
                let candidate = LibrarySnapshot(
                    schemaVersion: before.schemaVersion, revision: before.revision,
                    projects: projects ?? before.projects, tasks: tasks ?? before.tasks,
                    entries: before.entries, activeTimer: before.activeTimer,
                    pendingSleepIntervals: before.pendingSleepIntervals)
                let errors = SnapshotValidator.violations(in: candidate).filter { $0.code != .warning }
                if errors.contains(where: { $0.code == .allocation }) {
                    let editedID: UUID?
                    switch command {
                    case let .createTask(id, _, _, _, _), let .editTask(id, _, _): editedID = id
                    default: editedID = nil
                    }
                    if let id = editedID, let task = candidate.tasks.first(where: { $0.id == id }) {
                        let allowance = try BudgetRules.allowance(in: candidate, projectID: task.projectID,
                            parentTaskID: task.parentTaskID, editingTaskID: id)
                        throw CommandError.budgetAllocation(taskID: id, allowance: allowance)
                    }
                }
                guard errors.isEmpty else { throw LibraryError.invalid(errors) }
            }
            switch command {
            case let .createProject(id, title, rate, currency):
                guard !before.projects.contains(where: { $0.id == id }) else { throw CommandError.alreadyExists }
                let project = Project(id: id, name: name(title), hourlyRate: rate, currencyCode: currency)
                try validate(projects: before.projects + [project])
                var value = rate
                try db.runCommand("INSERT INTO projects(id,name,hourly_rate,currency_code) VALUES (?,?,?,?)",
                                  bindings: [key(id), .text(project.name), .text(NSDecimalString(&value, Locale(identifier: "en_US_POSIX"))), .text(currency)], expectedChanges: 1)
            case let .updateProject(id, title, rate, currency, confirmed):
                guard let old = before.projects.first(where: { $0.id == id }) else { throw CommandError.missingRecord }
                if let confirmed, confirmed != old.currencyCode { throw CommandError.currencyChanged }
                if old.currencyCode != currency,
                   before.entries.contains(where: { entry in before.tasks.contains { $0.id == entry.taskID && $0.projectID == id } }),
                   confirmed != old.currencyCode {
                    throw CommandError.currencyConfirmationRequired(old.currencyCode)
                }
                let project = Project(id: id, name: name(title), hourlyRate: rate, currencyCode: currency, isArchived: old.isArchived)
                try validate(projects: before.projects.map { $0.id == id ? project : $0 })
                var value = rate
                try db.runCommand("UPDATE projects SET name=?,hourly_rate=?,currency_code=? WHERE id=?",
                                  bindings: [.text(project.name), .text(NSDecimalString(&value, Locale(identifier: "en_US_POSIX"))), .text(currency), key(id)], expectedChanges: 1)
            case let .setArchived(id, archived):
                if archived, let active = before.activeTimer,
                   let entry = before.entries.first(where: { $0.id == active.entryID }),
                   before.tasks.contains(where: { $0.id == entry.taskID && $0.projectID == id }) {
                    throw CommandError.recoveryRequired
                }
                guard before.projects.contains(where: { $0.id == id }) else { throw CommandError.missingRecord }
                try db.runCommand("UPDATE projects SET is_archived=? WHERE id=?",
                                  bindings: [.integer(archived ? 1 : 0), key(id)], expectedChanges: 1)
            case let .createTask(id, projectID, parentID, title, budgetSeconds):
                let base = try taskForInsertion(id: id, projectID: projectID, parentID: parentID, name: title, in: before)
                let task = TaskRecord(id: base.id, projectID: base.projectID, parentTaskID: base.parentTaskID,
                                      name: base.name, budgetSeconds: budgetSeconds)
                if let parentID {
                    guard !before.entries.contains(where: { $0.taskID == parentID }),
                          !before.pendingSleepIntervals.contains(where: { $0.taskID == parentID }) else {
                        throw CommandError.migrationRequired
                    }
                }
                try validate(tasks: before.tasks + [task])
                try db.runCommand("INSERT INTO tasks(id,project_id,parent_task_id,name,budget_seconds) VALUES (?,?,?,?,?)",
                    bindings: [key(id), key(projectID), parentID.map(key) ?? .null, .text(task.name),
                               budgetSeconds.map(SQLValue.integer) ?? .null], expectedChanges: 1)
            case let .editTask(id, title, budgetSeconds):
                guard let old = before.tasks.first(where: { $0.id == id }),
                      let project = before.projects.first(where: { $0.id == old.projectID }) else {
                    throw CommandError.missingRecord
                }
                guard !project.isArchived else { throw CommandError.archivedProject }
                let task = TaskRecord(id: id, projectID: old.projectID, parentTaskID: old.parentTaskID,
                    name: name(title), budgetSeconds: budgetSeconds, lastWarnedThreshold: old.lastWarnedThreshold)
                try validate(tasks: before.tasks.map { $0.id == id ? task : $0 })
                try db.runCommand("UPDATE tasks SET name=?,budget_seconds=? WHERE id=?",
                    bindings: [.text(task.name), budgetSeconds.map(SQLValue.integer) ?? .null, key(id)], expectedChanges: 1)
            case let .renameTask(id, title):
                guard let old = before.tasks.first(where: { $0.id == id }),
                      let project = before.projects.first(where: { $0.id == old.projectID }) else { throw CommandError.missingRecord }
                guard !project.isArchived else { throw CommandError.archivedProject }
                let task = TaskRecord(id: id, projectID: old.projectID, parentTaskID: old.parentTaskID,
                                      name: name(title), budgetSeconds: old.budgetSeconds, lastWarnedThreshold: old.lastWarnedThreshold)
                try validate(tasks: before.tasks.map { $0.id == id ? task : $0 })
                try db.runCommand("UPDATE tasks SET name=? WHERE id=?", bindings: [.text(task.name), key(id)], expectedChanges: 1)
            }
        }
        return committed.snapshot
    }
}
