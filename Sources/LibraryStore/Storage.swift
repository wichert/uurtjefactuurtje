import Darwin
import Foundation
import SQLite3

// Internal until Slice 4 has supplied the process lock and private-copy installation.
enum StorageError: Error, Equatable {
    case sqlite(Int32, String)
    case invalidStorage(String)
    case unsupportedSchema(Int64)
    case revisionConflict(expected: Int64, actual: Int64)
    case revisionOverflow
    case commitIndeterminate
    case unavailable
    case injectedFailure
}

struct Committed<Value: Sendable>: Sendable {
    let value: Value
    let snapshot: LibrarySnapshot
}

enum CommitFault: Sendable { case none, beforeCommit, commitRejected, acknowledgementLost, rollbackFailure }

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLConnection {
    private var database: OpaquePointer?

    init(privatePath: String) throws {
        var opened: OpaquePointer?
        let resultCode = sqlite3_open_v2(privatePath, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil)
        guard resultCode == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            if let opened { sqlite3_close_v2(opened) }
            throw StorageError.sqlite(resultCode, message)
        }
        database = opened
        sqlite3_extended_result_codes(opened, 1)
    }

    deinit { close() }
    func close() {
        if let database {
            sqlite3_close_v2(database)
            self.database = nil
        }
    }
    var autocommit: Bool { database.map { sqlite3_get_autocommit($0) != 0 } ?? true }
    func allowOnlyCommandDML(_ enabled: Bool) throws {
        let database = try handle()
        commandWriteAuthorized = false
        let resultCode = sqlite3_set_authorizer(
            database,
            enabled
                ? { context, action, first, _, database, source in
                    switch action {
                    case SQLITE_SELECT, SQLITE_FUNCTION, SQLITE_RECURSIVE:
                        return SQLITE_OK
                    case SQLITE_READ:
                        guard let first, let database, String(cString: database) == "main" else { return SQLITE_DENY }
                        let table = String(cString: first)
                        return [
                            "library_metadata", "projects", "tasks", "time_entries", "active_timer",
                            "pending_sleep_intervals"
                        ].contains(table) ? SQLITE_OK : SQLITE_DENY
                    case SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE:
                        guard let first, let database, String(cString: database) == "main" else { return SQLITE_DENY }
                        let table = String(cString: first)
                        guard
                            ["projects", "tasks", "time_entries", "active_timer", "pending_sleep_intervals"].contains(
                                table), let context
                        else { return SQLITE_DENY }
                        if source == nil {
                            Unmanaged<SQLConnection>.fromOpaque(context).takeUnretainedValue().commandWriteAuthorized =
                                true
                        }
                        return SQLITE_OK
                    default:
                        return SQLITE_DENY
                    }
                } : nil, enabled ? Unmanaged.passUnretained(self).toOpaque() : nil)
        guard resultCode == SQLITE_OK else { throw failure(resultCode) }
    }
    private var commandWriteAuthorized = false
    private func handle() throws -> OpaquePointer {
        guard let database else { throw StorageError.unavailable }
        return database
    }
    private func failure(_ resultCode: Int32) -> StorageError {
        .sqlite(resultCode, database.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }
    func exec(_ sql: String) throws {
        let database = try handle()
        let resultCode = sqlite3_exec(database, sql, nil, nil, nil)
        guard resultCode == SQLITE_OK else { throw failure(resultCode) }
    }
    func rows<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> [T] {
        let database = try handle()
        var statement: OpaquePointer?
        let resultCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard resultCode == SQLITE_OK, let statement else { throw failure(resultCode) }
        defer { sqlite3_finalize(statement) }
        var values: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return values }
            guard step == SQLITE_ROW else { throw failure(step) }
            values.append(try body(statement))
        }
    }
    func run(_ sql: String, _ bindings: [SQLValue], requireDML: Bool = false) throws {
        let database = try handle()
        guard !sql.contains("\0"), sql.utf8.count <= Int(Int32.max) else {
            throw StorageError.invalidStorage("invalid SQL text")
        }
        commandWriteAuthorized = false
        var statement: OpaquePointer?
        let resultCode: Int32 = try sql.withCString { input in
            if requireDML {
                let keyword = String(cString: input).trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix { $0.isLetter }.uppercased()
                guard ["INSERT", "UPDATE", "DELETE", "WITH"].contains(keyword) else {
                    throw StorageError.invalidStorage("expected DML")
                }
            }
            var tail: UnsafePointer<CChar>?
            let resultCode = sqlite3_prepare_v2(database, input, -1, &statement, &tail)
            if resultCode == SQLITE_OK, let tail,
                !String(cString: tail).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let statement { sqlite3_finalize(statement) }
                statement = nil
                throw StorageError.invalidStorage("trailing SQL")
            }
            return resultCode
        }
        guard resultCode == SQLITE_OK, let statement else { throw failure(resultCode) }
        defer { sqlite3_finalize(statement) }
        guard !requireDML || (sqlite3_stmt_readonly(statement) == 0 && commandWriteAuthorized) else {
            throw StorageError.invalidStorage("expected DML")
        }
        guard bindings.count <= Int(Int32.max), sqlite3_bind_parameter_count(statement) == Int32(bindings.count) else {
            throw StorageError.invalidStorage("binding count")
        }
        for (offset, value) in bindings.enumerated() {
            let column = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, column)
            case .integer(let value): result = sqlite3_bind_int64(statement, column, value)
            case .text(let text):
                guard !text.contains("\0"), text.utf8.count <= Int(Int32.max) else {
                    throw StorageError.invalidStorage("invalid bound text")
                }
                result = text.withCString {
                    sqlite3_bind_text(statement, column, $0, Int32(text.utf8.count), transient)
                }
            }
            guard result == SQLITE_OK else { throw failure(result) }
        }
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE else { throw failure(step) }
    }
    var changes: Int { database.map { Int(sqlite3_changes($0)) } ?? 0 }
}

enum SQLValue: Sendable {
    case null
    case integer(Int64)
    case text(String)
}

private func integer(_ statement: OpaquePointer, _ column: Int32) throws -> Int64 {
    guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else {
        throw StorageError.invalidStorage("expected integer")
    }
    return sqlite3_column_int64(statement, column)
}
private func text(_ statement: OpaquePointer, _ column: Int32) throws -> String {
    guard sqlite3_column_type(statement, column) == SQLITE_TEXT, let pointer = sqlite3_column_text(statement, column)
    else {
        throw StorageError.invalidStorage("expected text")
    }
    let bytes = UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    guard let value = String(bytes: bytes, encoding: .utf8), !value.contains("\0") else {
        throw StorageError.invalidStorage("invalid text")
    }
    return value
}
private func optionalInteger(_ statement: OpaquePointer, _ column: Int32) throws -> Int64? {
    sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : try integer(statement, column)
}
private func uuid(_ statement: OpaquePointer, _ column: Int32) throws -> UUID {
    let raw = try text(statement, column)
    guard let value = UUID(uuidString: raw), value.uuidString.lowercased() == raw else {
        throw StorageError.invalidStorage("noncanonical UUID")
    }
    return value
}
private func optionalUUID(_ statement: OpaquePointer, _ column: Int32) throws -> UUID? {
    sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : try uuid(statement, column)
}

// NSDecimalString produces a non-exponent, locale-independent, exact canonical form.
func canonicalRate(_ rate: Decimal) throws -> String {
    guard !rate.isNaN, rate >= 0 else { throw StorageError.invalidStorage("invalid rate") }
    var value = rate
    return NSDecimalString(&value, Locale(identifier: "en_US_POSIX"))
}
private func rate(_ statement: OpaquePointer, _ column: Int32) throws -> Decimal {
    let raw = try text(statement, column)
    guard let parsed = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")),
        try canonicalRate(parsed) == raw
    else { throw StorageError.invalidStorage("noncanonical rate") }
    return parsed
}

// Exact CREATE statements make the greenfield schema an explicit allowlist, including
// constraints and indexes; unknown triggers, views, or schema variations fail closed.
// SQLite's canonical CREATE statements must remain byte-for-byte unchanged.
// swiftlint:disable line_length
private let schema: [(String, String, String)] = [
    (
        "table", "library_metadata",
        "CREATE TABLE library_metadata (id INTEGER PRIMARY KEY CHECK (id = 1), schema_version INTEGER NOT NULL CHECK (schema_version >= 1), revision INTEGER NOT NULL CHECK (revision >= 0))"
    ),
    (
        "table", "projects",
        "CREATE TABLE projects (id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL CHECK (length(trim(name)) > 0), hourly_rate TEXT NOT NULL, currency_code TEXT NOT NULL CHECK (length(currency_code) = 3), is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)))"
    ),
    (
        "table", "tasks",
        "CREATE TABLE tasks (id TEXT NOT NULL PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE RESTRICT, parent_task_id TEXT, name TEXT NOT NULL CHECK (length(trim(name)) > 0), budget_minutes INTEGER CHECK (budget_minutes > 0), last_warned_threshold INTEGER NOT NULL DEFAULT 0 CHECK (last_warned_threshold IN (0, 80, 100)), UNIQUE (id, project_id), FOREIGN KEY (parent_task_id, project_id) REFERENCES tasks(id, project_id) ON DELETE RESTRICT, CHECK (parent_task_id IS NULL OR parent_task_id <> id))"
    ),
    (
        "table", "time_entries",
        "CREATE TABLE time_entries (id TEXT NOT NULL PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE RESTRICT, start_at INTEGER NOT NULL, end_at INTEGER, CHECK (end_at IS NULL OR end_at > start_at))"
    ),
    (
        "table", "active_timer",
        "CREATE TABLE active_timer (id INTEGER PRIMARY KEY CHECK (id = 1), entry_id TEXT NOT NULL UNIQUE REFERENCES time_entries(id) ON DELETE RESTRICT, checkpoint_at INTEGER NOT NULL)"
    ),
    (
        "table", "pending_sleep_intervals",
        "CREATE TABLE pending_sleep_intervals (id TEXT NOT NULL PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE RESTRICT, sleep_at INTEGER NOT NULL, wake_at INTEGER, CHECK (wake_at IS NULL OR wake_at > sleep_at))"
    ),
    ("index", "tasks_by_parent", "CREATE INDEX tasks_by_parent ON tasks(project_id, parent_task_id)"),
    ("index", "entries_by_task_start", "CREATE INDEX entries_by_task_start ON time_entries(task_id, start_at)"),
    ("index", "entries_by_start", "CREATE INDEX entries_by_start ON time_entries(start_at)"),
    ("index", "one_open_entry", "CREATE UNIQUE INDEX one_open_entry ON time_entries((1)) WHERE end_at IS NULL"),
    ("index", "sleep_by_task", "CREATE INDEX sleep_by_task ON pending_sleep_intervals(task_id)"),
    (
        "index", "one_unknown_wake",
        "CREATE UNIQUE INDEX one_unknown_wake ON pending_sleep_intervals((1)) WHERE wake_at IS NULL"
    ),
    (
        "trigger", "active_timer_insert_valid",
        "CREATE TRIGGER active_timer_insert_valid BEFORE INSERT ON active_timer WHEN NOT EXISTS (SELECT 1 FROM time_entries WHERE id = NEW.entry_id AND end_at IS NULL AND start_at <= NEW.checkpoint_at) BEGIN SELECT RAISE(ABORT, 'invalid active timer'); END"
    ),
    (
        "trigger", "active_timer_update_valid",
        "CREATE TRIGGER active_timer_update_valid BEFORE UPDATE ON active_timer WHEN NOT EXISTS (SELECT 1 FROM time_entries WHERE id = NEW.entry_id AND end_at IS NULL AND start_at <= NEW.checkpoint_at) BEGIN SELECT RAISE(ABORT, 'invalid active timer'); END"
    ),
    (
        "trigger", "active_entry_update_valid",
        "CREATE TRIGGER active_entry_update_valid BEFORE UPDATE ON time_entries WHEN EXISTS (SELECT 1 FROM active_timer WHERE entry_id = OLD.id AND (NEW.end_at IS NOT NULL OR NEW.start_at > checkpoint_at)) BEGIN SELECT RAISE(ABORT, 'invalid active entry'); END"
    )
]

// swiftlint:enable line_length

private let schemaV1: [(String, String, String)] = schema.map { type, name, sql in
    (
        type, name,
        name == "tasks"
            ? sql.replacingOccurrences(of: "budget_minutes", with: "budget_seconds") : sql
    )
}

private func checkSchema(
    _ database: SQLConnection,
    expectedSchema: [(String, String, String)] = schema
) throws {
    let actual = try database.rows(
        "SELECT type, name, sql FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY type, name"
    ) {
        try [text($0, 0), text($0, 1), text($0, 2)]
    }
    let expected = expectedSchema.map { [$0.0, $0.1, $0.2] }
        .sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }
    guard actual == expected else { throw StorageError.invalidStorage("schema shape") }
}

private func configure(_ database: SQLConnection) throws {
    guard sqlite3_libversion_number() >= 3_025_000 else {
        throw StorageError.invalidStorage("SQLite runtime too old")
    }
    try database.exec("PRAGMA foreign_keys=ON")
    let journal = try database.rows("PRAGMA journal_mode=DELETE") { try text($0, 0) }
    try database.exec("PRAGMA synchronous=FULL")
    try database.exec("PRAGMA fullfsync=ON")
    let foreign = try database.rows("PRAGMA foreign_keys") { try integer($0, 0) }
    let synchronous = try database.rows("PRAGMA synchronous") { try integer($0, 0) }
    let flush = try database.rows("PRAGMA fullfsync") { try integer($0, 0) }
    guard journal == ["delete"], foreign == [1], synchronous == [2], flush == [1] else {
        throw StorageError.invalidStorage("required SQLite settings unavailable")
    }
}
private func checkIntegrity(_ database: SQLConnection) throws {
    let integrity = try database.rows("PRAGMA integrity_check") { try text($0, 0) }
    guard integrity == ["ok"] else { throw StorageError.invalidStorage("integrity_check") }
    let foreign = try database.rows("PRAGMA foreign_key_check") { _ in true }
    guard foreign.isEmpty else { throw StorageError.invalidStorage("foreign_key_check") }
}
private func decodeSnapshot(_ database: SQLConnection) throws -> LibrarySnapshot {
    let meta = try database.rows("SELECT id, schema_version, revision FROM library_metadata") {
        try (integer($0, 0), integer($0, 1), integer($0, 2))
    }
    guard meta.count == 1, meta[0].0 == 1 else { throw StorageError.invalidStorage("metadata singleton") }
    guard meta[0].1 == 2 else { throw StorageError.unsupportedSchema(meta[0].1) }
    let projects = try database.rows(
        "SELECT id, name, hourly_rate, currency_code, is_archived FROM projects ORDER BY id"
    ) { statement in
        let flag = try integer(statement, 4)
        guard flag == 0 || flag == 1 else { throw StorageError.invalidStorage("boolean") }
        return try Project(
            id: uuid(statement, 0), name: text(statement, 1), hourlyRate: rate(statement, 2),
            currencyCode: text(statement, 3),
            isArchived: flag == 1)
    }
    let tasks = try database.rows(
        "SELECT id, project_id, parent_task_id, name, budget_minutes, last_warned_threshold FROM tasks ORDER BY id"
    ) { statement in
        guard let warning = WarningThreshold(rawValue: try integer(statement, 5)) else {
            throw StorageError.invalidStorage("warning")
        }
        return try TaskRecord(
            id: uuid(statement, 0), projectID: uuid(statement, 1), parentTaskID: optionalUUID(statement, 2),
            name: text(statement, 3), budgetMinutes: optionalInteger(statement, 4), lastWarnedThreshold: warning)
    }
    let entries = try database.rows("SELECT id, task_id, start_at, end_at FROM time_entries ORDER BY id") { statement in
        try TimeEntry(
            id: uuid(statement, 0), taskID: uuid(statement, 1), startAt: integer(statement, 2),
            endAt: optionalInteger(statement, 3))
    }
    let timers = try database.rows("SELECT id, entry_id, checkpoint_at FROM active_timer") { statement in
        try (integer(statement, 0), ActiveTimer(entryID: uuid(statement, 1), checkpointAt: integer(statement, 2)))
    }
    guard timers.count <= 1, timers.first.map({ $0.0 == 1 }) ?? true else {
        throw StorageError.invalidStorage("timer singleton")
    }
    let pending = try database.rows(
        "SELECT id, task_id, sleep_at, wake_at FROM pending_sleep_intervals ORDER BY id"
    ) { statement in
        try PendingSleepInterval(
            id: uuid(statement, 0), taskID: uuid(statement, 1), sleepAt: integer(statement, 2),
            wakeAt: optionalInteger(statement, 3))
    }
    let snapshot = LibrarySnapshot(
        schemaVersion: meta[0].1, revision: meta[0].2, projects: projects, tasks: tasks,
        entries: entries, activeTimer: timers.first?.1, pendingSleepIntervals: pending)
    return snapshot
}

private func migrateV1(_ database: SQLConnection) throws {
    // Called only inside the initializer's transaction, after exact v1 shape/integrity checks.
    // Inspect every stored budget before any ALTER/UPDATE: numeric affinity would otherwise let the
    // `/ 60` arithmetic silently sanitize TEXT/BLOB/REAL values instead of failing closed.
    let stored = try database.rows("SELECT budget_seconds FROM tasks WHERE budget_seconds IS NOT NULL") {
        try integer($0, 0)  // existing strict codec: TEXT/BLOB/REAL throw invalidStorage("expected integer")
    }
    guard stored.allSatisfy({ $0 > 0 }) else {
        throw StorageError.invalidStorage("nonpositive budget_seconds")
    }
    try database.exec("ALTER TABLE tasks RENAME COLUMN budget_seconds TO budget_minutes")
    try database.exec(
        """
        UPDATE tasks SET budget_minutes = CASE
            WHEN budget_minutes IS NULL THEN NULL
            ELSE budget_minutes / 60 + CASE WHEN budget_minutes % 60 > 0 THEN 1 ELSE 0 END
        END
        """)
    try database.exec("UPDATE library_metadata SET schema_version=2 WHERE id=1")
    guard database.changes == 1 else { throw StorageError.invalidStorage("metadata singleton") }
    try checkSchema(database)
    try checkIntegrity(database)
    let candidate = try decodeSnapshot(database)
    let errors = SnapshotValidator.violations(in: candidate, now: nil).filter { $0.code != .warning }
    // Reject rounding-induced allocation conflicts; never expand ancestors.
    guard errors.isEmpty else { throw LibraryError.invalid(errors) }
    let totals = try BudgetRules.usage(in: candidate)
    for task in candidate.tasks {
        let band = BudgetRules.band(used: totals[task.id, default: 0], budget: task.budgetMinutes)
        if band != task.lastWarnedThreshold {
            try database.run(
                "UPDATE tasks SET last_warned_threshold=? WHERE id=?",
                [.integer(band.rawValue), .text(task.id.uuidString.lowercased())])
            guard database.changes == 1 else { throw StorageError.invalidStorage("unexpected affected row count") }
        }
    }
    _ = try load(database)
}

private func load(_ database: SQLConnection, now: Int64? = nil) throws -> LibrarySnapshot {
    let snapshot = try decodeSnapshot(database)
    try SnapshotValidator.validate(snapshot, now: now)
    return snapshot
}

// The caller owns the private working copy; canonical publication is separate.
actor Storage {
    private let connection: SQLConnection
    private var poisoned = false
    private var inCommand = false
    private var commandFailed = false

    init(privateDatabaseAt url: URL) throws {
        let database = try SQLConnection(privatePath: url.path)
        do {
            try configure(database)
            try database.exec("BEGIN IMMEDIATE")
            let meta = try database.rows("SELECT id, schema_version, revision FROM library_metadata") {
                try (integer($0, 0), integer($0, 1), integer($0, 2))
            }
            guard meta.count == 1, meta[0].0 == 1, meta[0].2 >= 0 else {
                throw StorageError.invalidStorage("metadata singleton")
            }
            switch meta[0].1 {
            case 1:
                try checkSchema(database, expectedSchema: schemaV1)
                try checkIntegrity(database)
                try migrateV1(database)
            case 2:
                try checkSchema(database)
                try checkIntegrity(database)
                _ = try load(database)
            default:
                throw StorageError.unsupportedSchema(meta[0].1)
            }
            try database.exec("COMMIT")
        } catch {
            if !database.autocommit { try? database.exec("ROLLBACK") }
            database.close()
            throw error
        }
        connection = database
    }

    static func createPrivateDatabase(at url: URL) throws {
        let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw StorageError.invalidStorage("cannot exclusively create private database") }
        guard Darwin.close(descriptor) == 0 else {
            _ = unlink(url.path)
            throw StorageError.invalidStorage("cannot close private database")
        }
        var journalWasAbsent = false
        do {
            for suffix in ["-journal", "-wal", "-shm"] {
                var info = stat()
                guard lstat(url.path + suffix, &info) != 0, errno == ENOENT else {
                    throw StorageError.invalidStorage("private database sidecar already exists or is inaccessible")
                }
            }
            journalWasAbsent = true
            let database = try SQLConnection(privatePath: url.path)
            defer { database.close() }
            try configure(database)
            try database.exec("BEGIN IMMEDIATE")
            do {
                for (_, _, statement) in schema { try database.exec(statement) }
                try database.exec("INSERT INTO library_metadata (id, schema_version, revision) VALUES (1, 2, 0)")
                try database.exec("COMMIT")
            } catch {
                try? database.exec("ROLLBACK")
                throw error
            }
        } catch {
            // The exclusive open created the main file; SQLite may have created its journal.
            _ = unlink(url.path)
            if journalWasAbsent { _ = unlink(url.path + "-journal") }
            throw error
        }
    }

    func close() {
        poisoned = true
        connection.close()
    }

    func snapshot() throws -> LibrarySnapshot {
        guard !poisoned else { throw StorageError.unavailable }
        try connection.exec("BEGIN")
        do {
            let result = try load(connection)
            try connection.exec("COMMIT")
            return result
        } catch {
            if !connection.autocommit {
                do { try connection.exec("ROLLBACK") } catch {
                    close()
                    throw StorageError.commitIndeterminate
                }
            }
            throw error
        }
    }

    func runCommand(_ sql: String, bindings: [SQLValue], expectedChanges: Int) throws {
        guard !poisoned else { throw StorageError.unavailable }
        guard inCommand, expectedChanges >= 0 else { throw StorageError.invalidStorage("command outside transaction") }
        do {
            try connection.run(sql, bindings, requireDML: true)
            guard connection.changes == expectedChanges else {
                throw StorageError.invalidStorage("unexpected affected row count")
            }
        } catch {
            commandFailed = true
            throw error
        }
    }

    private func reconcileBudgetBands(now: Int64?) throws {
        let candidate = try decodeSnapshot(connection)
        let errors = SnapshotValidator.violations(in: candidate, now: now).filter { $0.code != .warning }
        guard errors.isEmpty else { throw LibraryError.invalid(errors) }
        let totals = try BudgetRules.usage(in: candidate)
        for task in candidate.tasks {
            let band = BudgetRules.band(used: totals[task.id, default: 0], budget: task.budgetMinutes)
            if band != task.lastWarnedThreshold {
                try runCommand(
                    "UPDATE tasks SET last_warned_threshold=? WHERE id=?",
                    bindings: [.integer(band.rawValue), .text(task.id.uuidString.lowercased())], expectedChanges: 1)
            }
        }
    }

    func transact<Value: Sendable>(
        expectedRevision: Int64, validationNow: Int64? = nil,
        fault: CommitFault = .none,
        _ apply: @Sendable (isolated Storage, LibrarySnapshot) throws -> Value
    ) throws -> Committed<Value> {
        guard !poisoned else { throw StorageError.unavailable }
        try connection.exec("BEGIN IMMEDIATE")
        var commitStarted = false
        do {
            let before = try load(connection)
            guard before.revision == expectedRevision else {
                throw StorageError.revisionConflict(expected: expectedRevision, actual: before.revision)
            }
            guard before.revision < .max else { throw StorageError.revisionOverflow }
            try connection.allowOnlyCommandDML(true)
            commandFailed = false
            inCommand = true
            let value: Value
            do {
                value = try apply(self, before)
                try reconcileBudgetBands(now: validationNow)
            } catch {
                inCommand = false
                try connection.allowOnlyCommandDML(false)
                throw error
            }
            inCommand = false
            try connection.allowOnlyCommandDML(false)
            guard !commandFailed else { throw StorageError.invalidStorage("command failed") }
            guard !connection.autocommit else { throw StorageError.invalidStorage("command ended transaction") }
            try connection.run(
                "UPDATE library_metadata SET revision = ? WHERE id = 1 AND revision = ?",
                [.integer(before.revision + 1), .integer(before.revision)])
            guard connection.changes == 1 else { throw StorageError.invalidStorage("revision update") }
            let after = try load(connection, now: validationNow)
            if fault == .beforeCommit || fault == .rollbackFailure { throw StorageError.injectedFailure }
            if fault == .commitRejected { throw StorageError.sqlite(SQLITE_BUSY, "injected commit rejection") }
            commitStarted = true
            try connection.exec("COMMIT")
            if fault == .acknowledgementLost { throw StorageError.injectedFailure }
            return Committed(value: value, snapshot: after)
        } catch {
            inCommand = false
            if !connection.autocommit {
                do {
                    if fault == .rollbackFailure { throw StorageError.injectedFailure }
                    try connection.exec("ROLLBACK")
                    guard connection.autocommit else { throw StorageError.commitIndeterminate }
                } catch {
                    close()
                    throw StorageError.commitIndeterminate
                }
                throw error
            }
            if commitStarted {
                close()
                throw StorageError.commitIndeterminate
            }
            throw error
        }
    }
}
