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
    var db: OpaquePointer?
    let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil)
    guard rc == SQLITE_OK, let db else { throw StorageError.sqlite(rc, "open") }
    defer { sqlite3_close_v2(db) }
    let result = sqlite3_exec(db, sql, nil, nil, nil)
    guard result == SQLITE_OK else { throw StorageError.sqlite(result, String(cString: sqlite3_errmsg(db))) }
}

private func addProject(_ store: isolated Storage, id: String, name: String = "Client") throws {
    try store.runCommand("INSERT INTO projects (id, name, hourly_rate, currency_code, is_archived) VALUES (?, ?, ?, ?, ?)",
                         bindings: [.text(id), .text(name), .text("12.5"), .text("EUR"), .integer(0)], expectedChanges: 1)
}

@Suite struct StorageTests {
    @Test func creationAndReopen() async throws {
        try await withPrivateDatabase { url in
            let original = try Data(contentsOf: url)
            #expect(throws: StorageError.self) { try Storage.createPrivateDatabase(at: url) }
            #expect(try Data(contentsOf: url) == original)
            let store = try Storage(privateDatabaseAt: url)
            let snapshot = try await store.snapshot()
            #expect(snapshot.schemaVersion == 1 && snapshot.revision == 0 && snapshot.projects.isEmpty)
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
            "UPDATE library_metadata SET schema_version=2",
            "INSERT INTO projects VALUES ('ABC', 'Client', '1', 'EUR', 0)",
            "INSERT INTO projects VALUES ('00000000-0000-0000-0000-000000000001', 'Client', '01', 'EUR', 0)",
            "INSERT INTO projects VALUES ('00000000-0000-0000-0000-000000000001', CAST(x'ff' AS TEXT), '1', 'EUR', 0)",
            "INSERT INTO projects VALUES ('00000000-0000-0000-0000-000000000001', CAST(x'610062' AS TEXT), '1', 'EUR', 0)",
            "INSERT INTO tasks VALUES ('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', NULL, 'Task', NULL, 0)"
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
            let receipt = try await first.transact(expectedRevision: 0) { store, _ in try addProject(store, id: id); return 42 }
            #expect(receipt.value == 42 && receipt.snapshot.revision == 1)
            await #expect(throws: StorageError.revisionConflict(expected: 0, actual: 1)) {
                try await second.transact(expectedRevision: 0) { store, _ in
                    try addProject(store, id: UUID().uuidString.lowercased()); return ()
                }
            }
            #expect(try await second.snapshot().projects.count == 1)
            await #expect(throws: StorageError.self) {
                try await first.transact(expectedRevision: 1) { store, _ in
                    try store.runCommand("UPDATE projects SET name = ? WHERE id = ?", bindings: [.text("changed"), .text(id)], expectedChanges: 2)
                }
            }
            #expect(try await first.snapshot() == receipt.snapshot)
            await #expect(throws: StorageError.self) {
                try await first.transact(expectedRevision: 1) { store, _ in
                    try? store.runCommand("UPDATE projects SET name = ? WHERE id = ?", bindings: [.text("changed"), .text(id)], expectedChanges: 2)
                }
            }
            #expect(try await first.snapshot() == receipt.snapshot)
            let noop = try await first.transact(expectedRevision: 1) { _, _ in () }
            #expect(noop.snapshot.revision == 2)
            await first.close(); await second.close()
        }
    }

    @Test func commandBoundaryRejectsUnsafeSQL() async throws {
        try await withPrivateDatabase { url in
            let store = try Storage(privateDatabaseAt: url)
            await #expect(throws: StorageError.self) { try await store.runCommand("DELETE FROM projects", bindings: [], expectedChanges: 0) }
            for sql in ["UPDATE library_metadata SET revision=999", "COMMIT", "PRAGMA foreign_keys=OFF", "CREATE TABLE extra (id)", "DELETE FROM projects; DELETE FROM tasks", "SELECT * FROM projects", "REINDEX", "ANALYZE", "VACUUM"] {
                await #expect(throws: StorageError.self) {
                    try await store.transact(expectedRevision: 0) { actor, _ in
                        try actor.runCommand(sql, bindings: [], expectedChanges: 0)
                    }
                }
                #expect(try await store.snapshot().revision == 0)
            }
            await #expect(throws: StorageError.self) {
                try await store.transact(expectedRevision: 0) { actor, _ in
                    try actor.runCommand("DELETE FROM projects WHERE name=?", bindings: [.text("a\0b")], expectedChanges: 0)
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
            let p = UUID().uuidString.lowercased(), parent = UUID().uuidString.lowercased()
            let child = UUID().uuidString.lowercased(), e = UUID().uuidString.lowercased()
            _ = try await store.transact(expectedRevision: 0) { s, _ in
                try addProject(s, id: p)
                try s.runCommand("INSERT INTO tasks (id, project_id, name) VALUES (?, ?, ?)", bindings: [.text(parent), .text(p), .text("Generic")], expectedChanges: 1)
                try s.runCommand("INSERT INTO time_entries VALUES (?, ?, ?, NULL)", bindings: [.text(e), .text(parent), .integer(10)], expectedChanges: 1)
                try s.runCommand("INSERT INTO active_timer VALUES (1, ?, ?)", bindings: [.text(e), .integer(10)], expectedChanges: 1)
            }
            await #expect(throws: StorageError.self) {
                try await store.transact(expectedRevision: 1) { s, _ in
                    try s.runCommand("UPDATE time_entries SET end_at = ? WHERE id = ?", bindings: [.integer(20), .text(e)], expectedChanges: 1)
                }
            }
            _ = try await store.transact(expectedRevision: 1) { s, _ in
                try s.runCommand("INSERT INTO tasks (id, project_id, parent_task_id, name) VALUES (?, ?, ?, ?)", bindings: [.text(child), .text(p), .text(parent), .text("Child")], expectedChanges: 1)
                try s.runCommand("UPDATE time_entries SET task_id = ? WHERE id = ?", bindings: [.text(child), .text(e)], expectedChanges: 1)
                try s.runCommand("DELETE FROM active_timer WHERE id = 1", bindings: [], expectedChanges: 1)
                try s.runCommand("UPDATE time_entries SET end_at = ? WHERE id = ?", bindings: [.integer(20), .text(e)], expectedChanges: 1)
            }
            let result = try await store.snapshot()
            #expect(result.revision == 2 && result.entries.first?.taskID.uuidString.lowercased() == child && result.activeTimer == nil)
            await store.close()
        }
    }

    @Test func commitFaultsAndRealBusy() async throws {
        for fault in [CommitFault.beforeCommit, .commitRejected, .acknowledgementLost, .rollbackFailure] {
            try await withPrivateDatabase { url in
                let store = try Storage(privateDatabaseAt: url)
                let id = UUID().uuidString.lowercased()
                let expected: StorageError = (fault == .acknowledgementLost || fault == .rollbackFailure) ? .commitIndeterminate : (fault == .commitRejected ? .sqlite(SQLITE_BUSY, "injected commit rejection") : .injectedFailure)
                await #expect(throws: expected) { try await store.transact(expectedRevision: 0, fault: fault) { s, _ in try addProject(s, id: id) } }
                if fault == .acknowledgementLost || fault == .rollbackFailure {
                    await #expect(throws: StorageError.unavailable) { try await store.snapshot() }
                } else { #expect(try await store.snapshot().revision == 0) }
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
                try await store.transact(expectedRevision: 0) { s, _ in try addProject(s, id: UUID().uuidString.lowercased()) }
            }
            #expect(sqlite3_exec(reader, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
            #expect(try await store.snapshot().revision == 0)
            await store.close()
        }
    }
}
