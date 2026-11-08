import Foundation
import Testing
@testable import LibraryStore

private func commandDirectory() -> URL {
    URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path, isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func addEntry(_ library: Library, taskID: UUID, revision: Int64) async throws -> LibrarySnapshot {
    let committed = try await library.transact(expectedRevision: revision) { db, _ in
        try db.runCommand("INSERT INTO time_entries(id,task_id,start_at,end_at) VALUES (?,?,?,?)",
                          bindings: [.text(UUID().uuidString.lowercased()), .text(taskID.uuidString.lowercased()), .integer(10), .integer(20)], expectedChanges: 1)
    }
    return committed.snapshot
}

@Suite struct CommandsTests {
    @Test func durableProjectTaskEditsAndGuards() async throws {
        let directory = commandDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await Library.open(at: directory)
        let project = UUID(), task = UUID(), child = UUID(), other = UUID()
        var snapshot = try await library.snapshot()
        snapshot = try await library.perform(.createProject(id: project, name: " Client ", rate: Decimal(string: "12.3456789")!, currency: "EUR"), expectedRevision: snapshot.revision)
        #expect(snapshot.projects[0].name == "Client")
        snapshot = try await library.perform(.createTask(id: task, projectID: project, parentID: nil, name: " Work "), expectedRevision: snapshot.revision)
        snapshot = try await library.perform(.createTask(id: child, projectID: project, parentID: task, name: "Child"), expectedRevision: snapshot.revision)
        snapshot = try await library.perform(.renameTask(id: child, name: " Renamed "), expectedRevision: snapshot.revision)
        #expect(snapshot.tasks.first(where: { $0.id == child })?.parentTaskID == task)
        #expect(snapshot.tasks.first(where: { $0.id == child })?.name == "Renamed")
        snapshot = try await library.perform(.setArchived(id: project, archived: true), expectedRevision: snapshot.revision)
        let archived = snapshot
        await #expect(throws: CommandError.archivedProject) {
            try await library.perform(.renameTask(id: child, name: "Rejected"), expectedRevision: archived.revision)
        }
        #expect(try await library.snapshot() == archived)
        snapshot = try await library.perform(.setArchived(id: project, archived: false), expectedRevision: snapshot.revision)
        snapshot = try await library.perform(.createProject(id: other, name: "Other", rate: 0, currency: "USD"), expectedRevision: snapshot.revision)
        let before = snapshot
        await #expect(throws: CommandError.missingRecord) {
            try await library.perform(.createTask(id: UUID(), projectID: other, parentID: task, name: "Bad parent"), expectedRevision: before.revision)
        }
        await #expect(throws: CommandError.alreadyExists) {
            try await library.perform(.createProject(id: project, name: "Duplicate", rate: 0, currency: "EUR"), expectedRevision: before.revision)
        }
        await #expect(throws: CommandError.missingRecord) {
            try await library.perform(.updateProject(id: UUID(), name: "Missing", rate: 0, currency: "EUR", confirmedPreviousCurrency: nil), expectedRevision: before.revision)
        }
        do {
            _ = try await library.perform(.createTask(id: UUID(), projectID: project, parentID: task, name: "renamed"), expectedRevision: before.revision)
            Issue.record("duplicate sibling name accepted")
        } catch let LibraryError.invalid(violations) {
            #expect(violations.contains { $0.code == .siblingName })
        }
        do {
            _ = try await library.perform(.updateProject(id: project, name: " ", rate: -1, currency: "BAD", confirmedPreviousCurrency: nil), expectedRevision: before.revision)
            Issue.record("invalid project accepted")
        } catch is LibraryError { }
        #expect(try await library.snapshot() == before)
        await #expect(throws: StorageError.revisionConflict(expected: before.revision - 1, actual: before.revision)) {
            try await library.perform(.renameTask(id: child, name: "Stale"), expectedRevision: before.revision - 1)
        }
        await library.close()
        let reopened = try await Library.open(at: directory)
        #expect(try await reopened.snapshot() == before)
        #expect(before.projects.first(where: { $0.id == project })?.hourlyRate == Decimal(string: "12.3456789")!)
        await reopened.close()
    }

    @Test func migrationAndCurrencyConsentPreserveHistory() async throws {
        let directory = commandDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await Library.open(at: directory)
        let project = UUID(), task = UUID()
        var snapshot = try await library.perform(.createProject(id: project, name: "Client", rate: 25, currency: "EUR"), expectedRevision: 0)
        snapshot = try await library.perform(.createTask(id: task, projectID: project, parentID: nil, name: "Work"), expectedRevision: snapshot.revision)
        snapshot = try await addEntry(library, taskID: task, revision: snapshot.revision)
        let before = snapshot
        await #expect(throws: CommandError.migrationRequired) {
            try await library.perform(.createTask(id: UUID(), projectID: project, parentID: task, name: "Child"), expectedRevision: before.revision)
        }
        await #expect(throws: CommandError.currencyConfirmationRequired("EUR")) {
            try await library.perform(.updateProject(id: project, name: "Client", rate: 30, currency: "USD", confirmedPreviousCurrency: nil), expectedRevision: before.revision)
        }
        await #expect(throws: CommandError.currencyChanged) {
            try await library.perform(.updateProject(id: project, name: "Client", rate: 30, currency: "USD", confirmedPreviousCurrency: "GBP"), expectedRevision: before.revision)
        }
        #expect(try await library.snapshot() == before)
        snapshot = try await library.perform(.updateProject(id: project, name: "Client", rate: 30, currency: "USD", confirmedPreviousCurrency: "EUR"), expectedRevision: before.revision)
        #expect(snapshot.entries == before.entries)
        #expect(snapshot.projects[0].hourlyRate == 30 && snapshot.projects[0].currencyCode == "USD")
        await library.close()
    }

    @Test func pendingTimeBlocksCommandsWithoutMutation() async throws {
        let directory = commandDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await Library.open(at: directory)
        let project = UUID(), task = UUID()
        var snapshot = try await library.perform(.createProject(id: project, name: "Client", rate: 0, currency: "EUR"), expectedRevision: 0)
        snapshot = try await library.perform(.createTask(id: task, projectID: project, parentID: nil, name: "Work"), expectedRevision: snapshot.revision)
        snapshot = try await library.transact(expectedRevision: snapshot.revision) { db, _ in
            try db.runCommand("INSERT INTO pending_sleep_intervals(id,task_id,sleep_at,wake_at) VALUES (?,?,?,?)",
                              bindings: [.text(UUID().uuidString.lowercased()), .text(task.uuidString.lowercased()), .integer(10), .integer(20)], expectedChanges: 1)
        }.snapshot
        let before = snapshot
        await #expect(throws: CommandError.migrationRequired) {
            try await library.perform(.createTask(id: UUID(), projectID: project, parentID: task, name: "Child"), expectedRevision: before.revision)
        }
        await #expect(throws: CommandError.recoveryRequired) {
            try await library.perform(.renameTask(id: task, name: "Blocked"), expectedRevision: before.revision)
        }
        #expect(try await library.snapshot() == before)
        await library.close()
    }
}
