import Foundation
import SQLite3
import Testing

@testable import LibraryStore

private func withPrivateDatabase(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("private.sqlite")
    try Storage.createPrivateDatabase(at: url)
    try await body(url)
}

private func raw(_ url: URL, _ sql: String) throws {
    var database: OpaquePointer?
    let resultCode = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil)
    guard resultCode == SQLITE_OK, let database else { throw StorageError.sqlite(resultCode, "open") }
    defer { sqlite3_close_v2(database) }
    let result = sqlite3_exec(database, sql, nil, nil, nil)
    guard result == SQLITE_OK else { throw StorageError.sqlite(result, String(cString: sqlite3_errmsg(database))) }
}

private func addProject(_ store: isolated Storage, id: String, name: String = "Client") throws {
    try store.runCommand(
        "INSERT INTO projects (id, name, hourly_rate, currency_code, is_archived) VALUES (?, ?, ?, ?, ?)",
        bindings: [.text(id), .text(name), .text("12.5"), .text("EUR"), .integer(0)],
        expectedChanges: 1)
}

@Suite struct StorageTests {
    @Test func creationAndReopen() async throws {
        try await withPrivateDatabase { url in
            let original = try Data(contentsOf: url)
            #expect(throws: StorageError.self) { try Storage.createPrivateDatabase(at: url) }
            #expect(try Data(contentsOf: url) == original)
            let store = try Storage(privateDatabaseAt: url)
            let snapshot = try await store.snapshot()
            #expect(snapshot.schemaVersion == 2 && snapshot.revision == 0 && snapshot.projects.isEmpty)
            await store.close()
            await #expect(throws: StorageError.unavailable) { try await store.snapshot() }
            let reopened = try Storage(privateDatabaseAt: url)
            #expect(try await reopened.snapshot() == snapshot)
            await reopened.close()
        }
    }

    @Test func schemaAndStrictCodecsFailClosed() async throws {
        for mutation in [
            "CREATE VIEW extra AS SELECT * FROM projects",
            "DROP TRIGGER active_timer_insert_valid",
            "UPDATE library_metadata SET schema_version=3",
            "INSERT INTO projects VALUES ('ABC', 'Client', '1', 'EUR', 0)",
            "INSERT INTO projects VALUES ('00000000-0000-0000-0000-000000000001', 'Client', '01', 'EUR', 0)",
            "INSERT INTO projects VALUES ('00000000-0000-0000-0000-000000000001', CAST(x'ff' AS TEXT), '1', 'EUR', 0)",
            "INSERT INTO projects VALUES ('00000000-0000-0000-0000-000000000001', " +
                "CAST(x'610062' AS TEXT), '1', 'EUR', 0)",
            "INSERT INTO tasks VALUES ('00000000-0000-0000-0000-000000000002', " +
                "'00000000-0000-0000-0000-000000000001', NULL, 'Task', NULL, 0)"
        ] {
            try await withPrivateDatabase { url in
                try raw(url, mutation)
                let before = try Data(contentsOf: url)
                #expect(throws: (any Error).self) { _ = try Storage(privateDatabaseAt: url) }
                #expect(try Data(contentsOf: url) == before)
            }
        }
    }

    @Test func revisionsStaleActorsAndRollback() async throws {
        try await withPrivateDatabase { url in
            let first = try Storage(privateDatabaseAt: url)
            let second = try Storage(privateDatabaseAt: url)
            let id = UUID().uuidString.lowercased()
            let receipt = try await first.transact(expectedRevision: 0) { store, _ in
                try addProject(
                    store,
                    id: id)
                return 42
            }
            #expect(receipt.value == 42 && receipt.snapshot.revision == 1)
            await #expect(throws: StorageError.revisionConflict(expected: 0, actual: 1)) {
                try await second.transact(expectedRevision: 0) { store, _ in
                    try addProject(store, id: UUID().uuidString.lowercased())
                    return ()
                }
            }
            #expect(try await second.snapshot().projects.count == 1)
            await #expect(throws: StorageError.self) {
                try await first.transact(expectedRevision: 1) { store, _ in
                    try store.runCommand(
                        "UPDATE projects SET name = ? WHERE id = ?",
                        bindings: [
                            .text("changed"),
                            .text(id)
                        ], expectedChanges: 2)
                }
            }
            #expect(try await first.snapshot() == receipt.snapshot)
            await #expect(throws: StorageError.self) {
                try await first.transact(expectedRevision: 1) { store, _ in
                    try? store.runCommand(
                        "UPDATE projects SET name = ? WHERE id = ?",
                        bindings: [
                            .text("changed"),
                            .text(id)
                        ], expectedChanges: 2)
                }
            }
            #expect(try await first.snapshot() == receipt.snapshot)
            let noop = try await first.transact(expectedRevision: 1) { _, _ in () }
            #expect(noop.snapshot.revision == 2)
            await first.close()
            await second.close()
        }
    }

    @Test func commandBoundaryRejectsUnsafeSQL() async throws {
        try await withPrivateDatabase { url in
            let store = try Storage(privateDatabaseAt: url)
            await #expect(throws: StorageError.self) {
                try await store.runCommand(
                    "DELETE FROM projects",
                    bindings: [], expectedChanges: 0)
            }
            for sql in [
                "UPDATE library_metadata SET revision=999", "COMMIT", "PRAGMA foreign_keys=OFF",
                "CREATE TABLE extra (id)", "DELETE FROM projects; DELETE FROM tasks", "SELECT * FROM projects",
                "REINDEX", "ANALYZE", "VACUUM"
            ] {
                await #expect(throws: StorageError.self) {
                    try await store.transact(expectedRevision: 0) { actor, _ in
                        try actor.runCommand(sql, bindings: [], expectedChanges: 0)
                    }
                }
                #expect(try await store.snapshot().revision == 0)
            }
            await #expect(throws: StorageError.self) {
                try await store.transact(expectedRevision: 0) { actor, _ in
                    try actor.runCommand(
                        "DELETE FROM projects WHERE name=?", bindings: [.text("timer\0b")],
                        expectedChanges: 0)
                }
            }
            await #expect(throws: StorageError.self) {
                try await store.transact(expectedRevision: 0) { actor, _ in
                    try actor.runCommand("DELETE FROM projects WHERE name=?", bindings: [], expectedChanges: 0)
                }
            }
            await store.close()
        }
    }

    @Test func triggerOrderingAndMigrationIntermediateState() async throws {
        try await withPrivateDatabase { url in
            let store = try Storage(privateDatabaseAt: url)
            let project = UUID().uuidString.lowercased()
            let parent = UUID().uuidString.lowercased()
            let child = UUID().uuidString.lowercased()
            let entry = UUID().uuidString.lowercased()
            _ = try await store.transact(expectedRevision: 0) { statement, _ in
                try addProject(statement, id: project)
                try statement.runCommand(
                    "INSERT INTO tasks (id, project_id, name) VALUES (?, ?, ?)",
                    bindings: [.text(parent), .text(project), .text("Generic")], expectedChanges: 1)
                try statement.runCommand(
                    "INSERT INTO time_entries VALUES (?, ?, ?, NULL)",
                    bindings: [
                        .text(entry),
                        .text(parent), .integer(10)
                    ], expectedChanges: 1)
                try statement.runCommand(
                    "INSERT INTO active_timer VALUES (1, ?, ?)",
                    bindings: [
                        .text(entry),
                        .integer(10)
                    ], expectedChanges: 1)
            }
            await #expect(throws: StorageError.self) {
                try await store.transact(expectedRevision: 1) { statement, _ in
                    try statement.runCommand(
                        "UPDATE time_entries SET end_at = ? WHERE id = ?",
                        bindings: [.integer(20), .text(entry)], expectedChanges: 1)
                }
            }
            _ = try await store.transact(expectedRevision: 1) { statement, _ in
                try statement.runCommand(
                    "INSERT INTO tasks (id, project_id, parent_task_id, name) " + "VALUES (?, ?, ?, ?)",
                    bindings: [.text(child), .text(project), .text(parent), .text("Child")],
                    expectedChanges: 1)
                try statement.runCommand(
                    "UPDATE time_entries SET task_id = ? WHERE id = ?",
                    bindings: [
                        .text(child),
                        .text(entry)
                    ], expectedChanges: 1)
                try statement.runCommand("DELETE FROM active_timer WHERE id = 1", bindings: [], expectedChanges: 1)
                try statement.runCommand(
                    "UPDATE time_entries SET end_at = ? WHERE id = ?",
                    bindings: [
                        .integer(20),
                        .text(entry)
                    ], expectedChanges: 1)
            }
            let result = try await store.snapshot()
            #expect(
                result.revision == 2 && result.entries.first?.taskID.uuidString.lowercased() == child
                    && result.activeTimer == nil)
            await store.close()
        }
    }

    @Test func commitFaultsAndRealBusy() async throws {
        for fault in [CommitFault.beforeCommit, .commitRejected, .acknowledgementLost, .rollbackFailure] {
            try await withPrivateDatabase { url in
                let store = try Storage(privateDatabaseAt: url)
                let id = UUID().uuidString.lowercased()
                let expected: StorageError =
                    (fault == .acknowledgementLost || fault == .rollbackFailure)
                    ? .commitIndeterminate
                    : (fault == .commitRejected ? .sqlite(SQLITE_BUSY, "injected commit rejection") : .injectedFailure)
                await #expect(throws: expected) {
                    try await store.transact(
                        expectedRevision: 0,
                        fault: fault
                    ) { statement, _ in try addProject(statement, id: id) }
                }
                if fault == .acknowledgementLost || fault == .rollbackFailure {
                    await #expect(throws: StorageError.unavailable) { try await store.snapshot() }
                } else {
                    #expect(try await store.snapshot().revision == 0)
                }
                await store.close()
                let reopened = try Storage(privateDatabaseAt: url)
                #expect(try await reopened.snapshot().revision == (fault == .acknowledgementLost ? 1 : 0))
                await reopened.close()
            }
        }
        try await withPrivateDatabase { url in
            let store = try Storage(privateDatabaseAt: url)
            var reader: OpaquePointer?
            #expect(sqlite3_open_v2(url.path, &reader, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
            guard let reader else { throw StorageError.invalidStorage("reader") }
            defer { sqlite3_close_v2(reader) }
            #expect(sqlite3_exec(reader, "BEGIN; SELECT * FROM library_metadata", nil, nil, nil) == SQLITE_OK)
            await #expect(throws: StorageError.self) {
                try await store.transact(expectedRevision: 0) { statement, _ in
                    try addProject(
                        statement,
                        id: UUID().uuidString.lowercased())
                }
            }
            #expect(sqlite3_exec(reader, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
            #expect(try await store.snapshot().revision == 0)
            await store.close()
        }
    }
}

extension StorageTests {
    @Test func productionV1MigrationPreservesHierarchyEntriesPendingAndBands() async throws {
        let root = URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        try createProductionV1(url)
        let project = UUID()
        let parent = UUID()
        let leaf = UUID()
        let one = UUID()
        let hour = UUID()
        let huge = UUID()
        let entry = UUID()
        let active = UUID()
        let pending = UUID()
        func key(_ id: UUID) -> String { id.uuidString.lowercased() }
        try raw(
            url,
            """
            PRAGMA foreign_keys=ON;
            INSERT INTO projects VALUES ('\(key(project))','Client','12.5','EUR',0);
            INSERT INTO tasks VALUES ('\(key(parent))','\(key(project))',NULL,'Parent',NULL,0);
            INSERT INTO tasks VALUES ('\(key(leaf))','\(key(project))','\(key(parent))','Leaf',5400,80);
            INSERT INTO tasks VALUES ('\(key(one))','\(key(project))',NULL,'One',1,100);
            INSERT INTO tasks VALUES ('\(key(hour))','\(key(project))',NULL,'Hour',3600,0);
            INSERT INTO tasks VALUES ('\(key(huge))','\(key(project))',NULL,'Huge',9223372036854775807,0);
            INSERT INTO time_entries VALUES ('\(key(entry))','\(key(leaf))',0,4320);
            INSERT INTO time_entries VALUES ('\(key(active))','\(key(one))',5000,NULL);
            INSERT INTO active_timer VALUES (1,'\(key(active))',5001);
            INSERT INTO pending_sleep_intervals VALUES ('\(key(pending))','\(key(leaf))',4400,4500);
            """)
        let library = try await Library.open(at: root)
        let value = try await library.snapshot()
        #expect(value.schemaVersion == 2 && value.revision == 7)
        #expect(value.tasks.first { $0.id == parent }?.budgetMinutes == nil)
        #expect(value.tasks.first { $0.id == leaf }?.budgetMinutes == 90)
        #expect(value.tasks.first { $0.id == one }?.budgetMinutes == 1)
        #expect(value.tasks.first { $0.id == hour }?.budgetMinutes == 60)
        #expect(value.tasks.first { $0.id == huge }?.budgetMinutes == 153_722_867_280_912_931)
        #expect(value.tasks.first { $0.id == leaf }?.parentTaskID == parent)
        #expect(value.tasks.first { $0.id == leaf }?.lastWarnedThreshold == .eighty)
        #expect(value.tasks.first { $0.id == one }?.lastWarnedThreshold == WarningThreshold.none)
        #expect(value.entries.contains(TimeEntry(id: entry, taskID: leaf, startAt: 0, endAt: 4320)))
        #expect(value.activeTimer == ActiveTimer(entryID: active, checkpointAt: 5001))
        #expect(
            value.pendingSleepIntervals == [
                PendingSleepInterval(
                    id: pending, taskID: leaf,
                    sleepAt: 4400, wakeAt: 4500)
            ])
        try SnapshotValidator.validate(value)
        await library.close()
        let reopened = try await Library.open(at: root)
        #expect(try await reopened.snapshot() == value)
        await reopened.close()
        // Opening through Storage checks the exact v2 allowlist, all indexes/triggers included.
        let checked = try Storage(privateDatabaseAt: url)
        #expect(try await checked.snapshot() == value)
        await checked.close()
        // A real second project isolates the composite parent FK from projects(id).
        let secondProject = UUID().uuidString.lowercased()
        try raw(url, "INSERT INTO projects VALUES ('\(secondProject)','Second','1','USD',0)")
        #expect(throws: StorageError.self) {
            try raw(
                url,
                """
                PRAGMA foreign_keys=ON;
                UPDATE tasks SET project_id='\(secondProject)' WHERE id='\(key(leaf))';
                """)
        }
        // The original active-entry trigger must still reject closing an owned active row.
        #expect(throws: StorageError.self) {
            try raw(url, "UPDATE time_entries SET end_at=5002 WHERE id='\(key(active))'")
        }
    }

    @Test func roundedAllocationConflictDoesNotPublishCanonical() async throws {
        let root = URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        try createProductionV1(url)
        let project = UUID().uuidString.lowercased()
        let parent = UUID().uuidString.lowercased()
        try raw(
            url,
            """
            PRAGMA foreign_keys=ON;
            INSERT INTO projects VALUES ('\(project)','Client','1','EUR',0);
            INSERT INTO tasks VALUES ('\(parent)','\(project)',NULL,'Root',60,0);
            INSERT INTO tasks VALUES ('\(UUID().uuidString.lowercased())','\(project)','\(parent)','One',1,0);
            INSERT INTO tasks VALUES ('\(UUID().uuidString.lowercased())','\(project)','\(parent)','Rest',59,0);
            """)
        let bytes = try Data(contentsOf: url)
        do {
            let owner = try await Library.open(at: root)
            await owner.close()
            Issue.record("rounded over-allocation unexpectedly accepted")
        } catch LibraryError.invalid(let errors) {
            #expect(errors.contains { $0.code == .allocation })
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test(arguments: ["'thirty'", "x'33363030'"])
    func migrationRejectsNonIntegerV1BudgetStorageWithoutChangingCanonical(encoded: String) async throws {
        let root = URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        try createProductionV1(url)
        let project = UUID().uuidString.lowercased()
        // TEXT affinity does not convert these values, and `> 0` holds by SQLite type ordering, so the
        // historical CHECK accepts them: only the pre-migration storage-class check can reject them.
        try raw(
            url,
            """
            PRAGMA foreign_keys=ON;
            INSERT INTO projects VALUES ('\(project)','Client','1','EUR',0);
            INSERT INTO tasks VALUES ('\(UUID().uuidString.lowercased())','\(project)',NULL,'Corrupt',\(encoded),0);
            """)
        let bytes = try Data(contentsOf: url)
        await #expect(throws: StorageError.invalidStorage("expected integer")) {
            try await Library.open(at: root)
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func migrationRejectsUnknownV1ShapeWithoutChangingCanonical() async throws {
        let root = URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        try createProductionV1(url)
        try raw(url, "CREATE VIEW extra AS SELECT * FROM tasks")
        let bytes = try Data(contentsOf: url)
        await #expect(throws: StorageError.invalidStorage("schema shape")) {
            try await Library.open(at: root)
        }
        #expect(try Data(contentsOf: url) == bytes)
    }
}

extension StorageTests {
    @Test(arguments: [
        "DROP INDEX tasks_by_parent; CREATE INDEX tasks_by_parent ON tasks(parent_task_id)",
        "DROP TRIGGER active_timer_update_valid; CREATE TRIGGER active_timer_update_valid " +
            "BEFORE UPDATE ON active_timer BEGIN SELECT 1; END"
    ])
    func v1IndexAndTriggerMutationsAreRejected(mutation: String) async throws {
        let root = URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        try createProductionV1(url)
        try raw(url, mutation)
        let before = try Data(contentsOf: url)
        await #expect(throws: StorageError.invalidStorage("schema shape")) { try await Library.open(at: root) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func v1UnknownWakeWithoutActiveTimerSurvivesUpgrade() async throws {
        let root = URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        try createProductionV1(url)
        let project = UUID()
        let task = UUID()
        let pending = UUID()
        func key(_ id: UUID) -> String { id.uuidString.lowercased() }
        try raw(
            url,
            """
            INSERT INTO projects VALUES ('\(key(project))','Client','1','EUR',0);
            INSERT INTO tasks VALUES ('\(key(task))','\(key(project))',NULL,'Work',59,0);
            INSERT INTO pending_sleep_intervals VALUES ('\(key(pending))','\(key(task))',100,NULL);
            """)
        let owner = try await Library.open(at: root)
        let state = try await owner.snapshot()
        #expect(state.tasks.first?.budgetMinutes == 1 && state.activeTimer == nil)
        #expect(
            state.pendingSleepIntervals == [
                PendingSleepInterval(
                    id: pending, taskID: task, sleepAt: 100,
                    wakeAt: nil)
            ])
        await owner.close()
        let bytes = try Data(contentsOf: url)
        let reopened = try await Library.open(at: root)
        #expect(try await reopened.snapshot() == state)
        await reopened.close()
        #expect(try Data(contentsOf: url) == bytes)
    }
}
