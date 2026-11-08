import Foundation
import Testing
@testable import LibraryStore

@Suite struct TaskMigrationTests {
    private func fixture(pending: Bool = false) async throws -> (URL, Library, UUID, UUID, LibrarySnapshot, UUID) {
        let directory = URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let library = try await Library.open(at: directory)
        let project = UUID(), parent = UUID(), record = UUID()
        var snapshot = try await library.perform(.createProject(id: project, name: "Client", rate: 1, currency: "EUR"), expectedRevision: 0)
        snapshot = try await library.perform(.createTask(id: parent, projectID: project, parentID: nil, name: "Parent"), expectedRevision: snapshot.revision)
        snapshot = try await library.transact(expectedRevision: snapshot.revision) { db, _ in
            if pending {
                try db.runCommand("INSERT INTO pending_sleep_intervals(id,task_id,sleep_at,wake_at) VALUES (?,?,?,?)",
                                  bindings: [.text(record.uuidString.lowercased()), .text(parent.uuidString.lowercased()), .integer(10), .integer(20)], expectedChanges: 1)
            } else {
                try db.runCommand("INSERT INTO time_entries(id,task_id,start_at,end_at) VALUES (?,?,?,?)",
                                  bindings: [.text(record.uuidString.lowercased()), .text(parent.uuidString.lowercased()), .integer(10), .integer(20)], expectedChanges: 1)
            }
        }.snapshot
        return (directory, library, project, parent, snapshot, record)
    }

    @Test func migrationUndoPreservesUnrelatedWrites() async throws {
        let (directory, library, project, parent, before, entry) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let child = UUID()
        let request = TaskCreationRequest(id: child, projectID: project, parentID: parent, name: "Child", confirmMigration: true, start: false)
        let result = try await library.createTask(request, expectedRevision: before.revision)
        let generic = try #require(result.genericID)
        #expect(result.snapshot.revision == before.revision + 1 && result.movedEntryCount == 1)
        #expect(result.snapshot.entries.first == TimeEntry(id: entry, taskID: generic, startAt: 10, endAt: 20))
        let availability = try await library.migrationUndoAvailability()
        guard case let .available(receipt) = availability else { Issue.record("Undo not available"); return }
        let edited = try await library.perform(.updateProject(id: project, name: "Updated", rate: 2, currency: "EUR", confirmedPreviousCurrency: nil), expectedRevision: result.snapshot.revision)
        #expect(try await library.migrationUndoAvailability() == availability)
        let undone = try await library.undoTaskMigration(receiptID: receipt)
        #expect(undone.revision == edited.revision + 1 && undone.projects.first?.name == "Updated")
        #expect(undone.entries.first == before.entries.first && undone.tasks == before.tasks)
        guard case .unavailable = try await library.migrationUndoAvailability() else { Issue.record("Receipt not consumed"); return }
        await library.close()
    }

    @Test func pendingOnlyMigrationAndUndoDuringReview() async throws {
        let (directory, library, project, parent, before, pending) = try await fixture(pending: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = TaskCreationRequest(id: UUID(), projectID: project, parentID: parent, name: "Child", confirmMigration: true, start: false)
        let result = try await library.createTask(request, expectedRevision: before.revision)
        #expect(result.movedPendingCount == 1 && result.snapshot.pendingSleepIntervals.first?.id == pending)
        guard case let .available(receipt) = try await library.migrationUndoAvailability() else { Issue.record("Undo not available"); return }
        let undone = try await library.undoTaskMigration(receiptID: receipt)
        #expect(undone.pendingSleepIntervals == before.pendingSleepIntervals)
        await library.close()
    }

    @Test func consentConflictsAndGuardAreAtomic() async throws {
        let (directory, library, project, parent, before, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let child = UUID()
        await #expect(throws: CommandError.migrationConfirmationRequired) {
            try await library.createTask(TaskCreationRequest(id: child, projectID: project, parentID: parent, name: "Child", confirmMigration: false, start: false), expectedRevision: before.revision)
        }
        await #expect(throws: CommandError.genericNameConflict) {
            try await library.createTask(TaskCreationRequest(id: child, projectID: project, parentID: parent, name: " generic ", confirmMigration: true, start: false), expectedRevision: before.revision)
        }
        #expect(try await library.snapshot() == before)
        let result = try await library.createTask(TaskCreationRequest(id: child, projectID: project, parentID: parent, name: "Child", confirmMigration: true, start: false), expectedRevision: before.revision)
        guard case let .available(receipt) = try await library.migrationUndoAvailability() else { Issue.record("Undo not available"); return }
        let renamed = try await library.perform(.renameTask(id: child, name: "Changed"), expectedRevision: result.snapshot.revision)
        guard case .unavailable = try await library.migrationUndoAvailability() else { Issue.record("Changed task allowed undo"); return }
        await #expect(throws: CommandError.undoUnavailable) { try await library.undoTaskMigration(receiptID: receipt) }
        #expect(try await library.snapshot() == renamed)
        await library.close()
    }

    enum TimeMutation: CaseIterable, Equatable, Sendable {
        case requestedEntry, genericEntry, movedEntry, movedAway, pending, requestedPending
    }

    @Test(arguments: TimeMutation.allCases)
    func changedTimeBlocksUndo(_ mutation: TimeMutation) async throws {
        let (directory, library, project, parent, before, entry) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let child = UUID(), other = UUID()
        let prepared = try await library.perform(.createTask(id: other, projectID: project, parentID: nil, name: "Other"), expectedRevision: before.revision)
        let result = try await library.createTask(
            TaskCreationRequest(id: child, projectID: project, parentID: parent, name: "Child", confirmMigration: true, start: false),
            expectedRevision: prepared.revision)
        let generic = try #require(result.genericID)
        guard case let .available(receipt) = try await library.migrationUndoAvailability() else { Issue.record("Undo not available"); return }
        let newID = UUID()
        let changed = try await library.transact(expectedRevision: result.snapshot.revision) { db, _ in
            switch mutation {
            case .requestedEntry, .genericEntry:
                let owner = mutation == .requestedEntry ? child : generic
                try db.runCommand("INSERT INTO time_entries(id,task_id,start_at,end_at) VALUES (?,?,?,?)",
                                  bindings: [.text(newID.uuidString.lowercased()), .text(owner.uuidString.lowercased()), .integer(30), .integer(40)], expectedChanges: 1)
            case .movedEntry:
                try db.runCommand("UPDATE time_entries SET end_at=? WHERE id=?",
                                  bindings: [.integer(21), .text(entry.uuidString.lowercased())], expectedChanges: 1)
            case .movedAway:
                try db.runCommand("UPDATE time_entries SET task_id=? WHERE id=?",
                                  bindings: [.text(other.uuidString.lowercased()), .text(entry.uuidString.lowercased())], expectedChanges: 1)
            case .pending, .requestedPending:
                let owner = mutation == .pending ? generic : child
                try db.runCommand("INSERT INTO pending_sleep_intervals(id,task_id,sleep_at,wake_at) VALUES (?,?,?,?)",
                                  bindings: [.text(newID.uuidString.lowercased()), .text(owner.uuidString.lowercased()), .integer(30), .integer(40)], expectedChanges: 1)
            }
        }.snapshot
        let reason = mutation == .requestedEntry || mutation == .requestedPending
            ? "New task owns time or pending sleep" : "Time, sleep or timer changed"
        #expect(try await library.migrationUndoAvailability() == .unavailable(reason: reason))
        await #expect(throws: CommandError.undoUnavailable) { try await library.undoTaskMigration(receiptID: receipt) }
        #expect(try await library.snapshot() == changed)
        await library.close()
    }

    @Test func newDescendantBlocksUndo() async throws {
        let (directory, library, project, parent, before, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let child = UUID()
        let result = try await library.createTask(
            TaskCreationRequest(id: child, projectID: project, parentID: parent, name: "Child", confirmMigration: true, start: false),
            expectedRevision: before.revision)
        guard case let .available(receipt) = try await library.migrationUndoAvailability() else { Issue.record("Undo not available"); return }
        let changed = try await library.perform(.createTask(id: UUID(), projectID: project, parentID: child, name: "Grandchild"), expectedRevision: result.snapshot.revision)
        #expect(try await library.migrationUndoAvailability() == .unavailable(reason: "Task hierarchy changed"))
        await #expect(throws: CommandError.undoUnavailable) { try await library.undoTaskMigration(receiptID: receipt) }
        #expect(try await library.snapshot() == changed)
        await library.close()
    }

    @Test func checkpointOnMigratedTimerBlocksUndo() async throws {
        let (directory, library, project, parent, before, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = UUID()
        let started = try await library.performTimer(.start(taskID: parent), expectedRevision: before.revision, instant: 30, newEntryID: entry)
        let result = try await library.createTaskOwned(
            TaskCreationRequest(id: UUID(), projectID: project, parentID: parent, name: "Child", confirmMigration: true, start: false),
            expectedRevision: started.revision, ownedTimerEntryID: entry, instant: nil)
        #expect(result.snapshot.activeTimer == started.activeTimer)
        #expect(result.snapshot.entries.first(where: { $0.id == entry })?.taskID == result.genericID)
        guard case let .available(receipt) = try await library.migrationUndoAvailability(ownedTimerEntryID: entry) else { Issue.record("Undo not available"); return }
        let changed = try await library.performTimer(.checkpoint, expectedRevision: result.snapshot.revision, instant: 40, newEntryID: UUID())
        #expect(try await library.migrationUndoAvailability(ownedTimerEntryID: entry) == .unavailable(reason: "Time, sleep or timer changed"))
        await #expect(throws: CommandError.undoUnavailable) { try await library.undoTaskMigration(receiptID: receipt, ownedTimerEntryID: entry) }
        #expect(try await library.snapshot() == changed)
        await library.close()
    }

    @Test func unrelatedOwnedTimerAndEditsSurviveUndo() async throws {
        let (directory, library, project, parent, before, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = UUID()
        let prepared = try await library.perform(.createTask(id: other, projectID: project, parentID: nil, name: "Other"), expectedRevision: before.revision)
        let result = try await library.createTask(
            TaskCreationRequest(id: UUID(), projectID: project, parentID: parent, name: "Child", confirmMigration: true, start: false),
            expectedRevision: prepared.revision)
        guard case let .available(receipt) = try await library.migrationUndoAvailability() else { Issue.record("Undo not available"); return }
        let timer = UUID()
        let started = try await library.performTimer(.start(taskID: other), expectedRevision: result.snapshot.revision, instant: 30, newEntryID: timer)
        #expect(try await library.migrationUndoAvailability() == .unavailable(reason: "Active timer requires review"))
        #expect(try await library.migrationUndoAvailability(ownedTimerEntryID: timer) == .available(receiptID: receipt))
        let edited = try await library.performOwned(.renameTask(id: other, name: "Unrelated edit"), expectedRevision: started.revision, ownedTimerEntryID: timer)
        let checkpointed = try await library.performTimer(.checkpoint, expectedRevision: edited.revision, instant: 40, newEntryID: UUID())
        #expect(try await library.migrationUndoAvailability(ownedTimerEntryID: timer) == .available(receiptID: receipt))
        let undone = try await library.undoTaskMigration(receiptID: receipt, ownedTimerEntryID: timer)
        #expect(undone.revision == checkpointed.revision + 1 && undone.activeTimer == checkpointed.activeTimer)
        #expect(undone.entries.first(where: { $0.id == timer }) == checkpointed.entries.first(where: { $0.id == timer }))
        #expect(undone.entries.first(where: { $0.id != timer }) == before.entries.first)
        #expect(undone.tasks.first(where: { $0.id == other })?.name == "Unrelated edit")
        await library.close()
    }

    @Test func emptyCreationAndStaleMigrationPreserveReceipt() async throws {
        let (directory, library, project, parent, before, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await library.createTask(
            TaskCreationRequest(id: UUID(), projectID: project, parentID: parent, name: "Child", confirmMigration: true, start: false),
            expectedRevision: before.revision)
        guard case let .available(receipt) = try await library.migrationUndoAvailability() else { Issue.record("Undo not available"); return }
        let emptyID = UUID()
        let empty = try await library.createTask(
            TaskCreationRequest(id: emptyID, projectID: project, parentID: nil, name: "Empty", confirmMigration: false, start: false),
            expectedRevision: result.snapshot.revision)
        let emptyChild = try await library.createTask(
            TaskCreationRequest(id: UUID(), projectID: project, parentID: emptyID, name: "Empty child", confirmMigration: false, start: false),
            expectedRevision: empty.snapshot.revision)
        #expect(empty.genericID == nil && emptyChild.genericID == nil)
        #expect(emptyChild.movedEntryCount == 0 && emptyChild.movedPendingCount == 0)
        #expect(try await library.migrationUndoAvailability() == .available(receiptID: receipt))
        let generic = try #require(result.genericID)
        let request = TaskCreationRequest(id: UUID(), projectID: project, parentID: generic, name: "Stale", confirmMigration: true, start: false)
        await #expect(throws: StorageError.revisionConflict(expected: result.snapshot.revision, actual: emptyChild.snapshot.revision)) {
            try await library.createTask(request, expectedRevision: result.snapshot.revision)
        }
        #expect(try await library.snapshot() == emptyChild.snapshot)
        #expect(try await library.migrationUndoAvailability() == .available(receiptID: receipt))
        let undone = try await library.undoTaskMigration(receiptID: receipt)
        #expect(undone.tasks.contains { $0.name == "Empty" } && undone.entries == before.entries)
        await library.close()
    }

    @Test func replacementAndRollbackReceiptLifecycle() async throws {
        let (directory, library, project, parent, before, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = UUID(), otherEntry = UUID(), child = UUID()
        let prepared = try await library.perform(.createTask(id: other, projectID: project, parentID: nil, name: "Other"), expectedRevision: before.revision)
        let withEntry = try await library.transact(expectedRevision: prepared.revision) { db, _ in
            try db.runCommand("INSERT INTO time_entries(id,task_id,start_at,end_at) VALUES (?,?,?,?)",
                              bindings: [.text(otherEntry.uuidString.lowercased()), .text(other.uuidString.lowercased()), .integer(30), .integer(40)], expectedChanges: 1)
        }.snapshot
        let first = try await library.createTask(
            TaskCreationRequest(id: UUID(), projectID: project, parentID: parent, name: "Child", confirmMigration: true, start: false),
            expectedRevision: withEntry.revision)
        guard case let .available(firstReceipt) = try await library.migrationUndoAvailability() else { Issue.record("Undo not available"); return }
        let request = TaskCreationRequest(id: child, projectID: project, parentID: other, name: "Second child", confirmMigration: true, start: false)
        let rejected = TaskCreationRequest(id: child, projectID: project, parentID: other, name: "Second child", confirmMigration: false, start: false)
        await #expect(throws: CommandError.migrationConfirmationRequired) {
            try await library.createTask(rejected, expectedRevision: first.snapshot.revision)
        }
        await #expect(throws: StorageError.injectedFailure) {
            try await library.transact(expectedRevision: first.snapshot.revision) { db, snapshot -> Void in
                _ = try createMigratingTask(request, before: snapshot, db: db, ownedTimerEntryID: nil, instant: nil, newEntryID: UUID())
                throw StorageError.injectedFailure
            }
        }
        #expect(try await library.snapshot() == first.snapshot)
        #expect(try await library.migrationUndoAvailability() == .available(receiptID: firstReceipt))
        let second = try await library.createTask(request, expectedRevision: first.snapshot.revision)
        let secondGeneric = try #require(second.genericID)
        #expect(second.movedEntryCount == 1 && second.movedPendingCount == 0)
        #expect(second.snapshot.entries.first(where: { $0.id == otherEntry })?.taskID == secondGeneric)
        guard case let .available(secondReceipt) = try await library.migrationUndoAvailability() else { Issue.record("Replacement undo not available"); return }
        #expect(secondReceipt != firstReceipt)
        await #expect(throws: CommandError.undoUnavailable) { try await library.undoTaskMigration(receiptID: firstReceipt) }
        #expect(try await library.snapshot() == second.snapshot)
        let undone = try await library.undoTaskMigration(receiptID: secondReceipt)
        #expect(undone.entries.first(where: { $0.id == otherEntry })?.taskID == other)
        #expect(undone.entries.first(where: { $0.id == before.entries.first?.id })?.taskID == first.genericID)
        #expect(!undone.tasks.contains(where: { $0.id == child || $0.id == secondGeneric }))
        #expect(try await library.migrationUndoAvailability() == .unavailable(reason: "No migration to undo"))
        await #expect(throws: CommandError.undoUnavailable) { try await library.undoTaskMigration(receiptID: secondReceipt) }
        #expect(try await library.snapshot() == undone)
        await library.close()
    }

    @Test func reopeningDiscardsAvailableReceipt() async throws {
        let (directory, library, project, parent, before, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await library.createTask(
            TaskCreationRequest(id: UUID(), projectID: project, parentID: parent, name: "Child", confirmMigration: true, start: false),
            expectedRevision: before.revision)
        guard case let .available(receipt) = try await library.migrationUndoAvailability() else { Issue.record("Undo not available"); return }
        await library.close()
        let reopened = try await Library.open(at: directory)
        #expect(try await reopened.snapshot() == result.snapshot)
        #expect(try await reopened.migrationUndoAvailability() == .unavailable(reason: "No migration to undo"))
        await #expect(throws: CommandError.undoUnavailable) { try await reopened.undoTaskMigration(receiptID: receipt) }
        #expect(try await reopened.snapshot() == result.snapshot)
        await reopened.close()
    }

    @Test func startMakesMigrationImmediatelyUnavailable() async throws {
        let (directory, library, project, parent, before, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = TaskCreationRequest(id: UUID(), projectID: project, parentID: parent, name: "Child", confirmMigration: true, start: true)
        let result = try await library.createTaskOwned(request, expectedRevision: before.revision, ownedTimerEntryID: nil, instant: 30)
        #expect(result.snapshot.revision == before.revision + 1 && result.snapshot.activeTimer != nil)
        guard case .unavailable = try await library.migrationUndoAvailability(ownedTimerEntryID: result.snapshot.activeTimer?.entryID) else {
            Issue.record("Started child allowed undo"); return
        }
        await library.close()
    }
}
