import Foundation
import SQLite3
@testable import LibraryStore

let productionV1DDL = """
CREATE TABLE library_metadata (id INTEGER PRIMARY KEY CHECK (id = 1), schema_version INTEGER NOT NULL CHECK (schema_version >= 1), revision INTEGER NOT NULL CHECK (revision >= 0));
CREATE TABLE projects (id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL CHECK (length(trim(name)) > 0), hourly_rate TEXT NOT NULL, currency_code TEXT NOT NULL CHECK (length(currency_code) = 3), is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)));
CREATE TABLE tasks (id TEXT NOT NULL PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE RESTRICT, parent_task_id TEXT, name TEXT NOT NULL CHECK (length(trim(name)) > 0), budget_seconds INTEGER CHECK (budget_seconds > 0), last_warned_threshold INTEGER NOT NULL DEFAULT 0 CHECK (last_warned_threshold IN (0, 80, 100)), UNIQUE (id, project_id), FOREIGN KEY (parent_task_id, project_id) REFERENCES tasks(id, project_id) ON DELETE RESTRICT, CHECK (parent_task_id IS NULL OR parent_task_id <> id));
CREATE TABLE time_entries (id TEXT NOT NULL PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE RESTRICT, start_at INTEGER NOT NULL, end_at INTEGER, CHECK (end_at IS NULL OR end_at > start_at));
CREATE TABLE active_timer (id INTEGER PRIMARY KEY CHECK (id = 1), entry_id TEXT NOT NULL UNIQUE REFERENCES time_entries(id) ON DELETE RESTRICT, checkpoint_at INTEGER NOT NULL);
CREATE TABLE pending_sleep_intervals (id TEXT NOT NULL PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE RESTRICT, sleep_at INTEGER NOT NULL, wake_at INTEGER, CHECK (wake_at IS NULL OR wake_at > sleep_at));
CREATE INDEX tasks_by_parent ON tasks(project_id, parent_task_id);
CREATE INDEX entries_by_task_start ON time_entries(task_id, start_at);
CREATE INDEX entries_by_start ON time_entries(start_at);
CREATE UNIQUE INDEX one_open_entry ON time_entries((1)) WHERE end_at IS NULL;
CREATE INDEX sleep_by_task ON pending_sleep_intervals(task_id);
CREATE UNIQUE INDEX one_unknown_wake ON pending_sleep_intervals((1)) WHERE wake_at IS NULL;
CREATE TRIGGER active_timer_insert_valid BEFORE INSERT ON active_timer WHEN NOT EXISTS (SELECT 1 FROM time_entries WHERE id = NEW.entry_id AND end_at IS NULL AND start_at <= NEW.checkpoint_at) BEGIN SELECT RAISE(ABORT, 'invalid active timer'); END;
CREATE TRIGGER active_timer_update_valid BEFORE UPDATE ON active_timer WHEN NOT EXISTS (SELECT 1 FROM time_entries WHERE id = NEW.entry_id AND end_at IS NULL AND start_at <= NEW.checkpoint_at) BEGIN SELECT RAISE(ABORT, 'invalid active timer'); END;
CREATE TRIGGER active_entry_update_valid BEFORE UPDATE ON time_entries WHEN EXISTS (SELECT 1 FROM active_timer WHERE entry_id = OLD.id AND (NEW.end_at IS NOT NULL OR NEW.start_at > checkpoint_at)) BEGIN SELECT RAISE(ABORT, 'invalid active entry'); END;
INSERT INTO library_metadata VALUES (1,1,7);
"""

func createProductionV1(_ url: URL) throws {
    var db: OpaquePointer?
    let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    guard rc == SQLITE_OK, let db else { throw StorageError.sqlite(rc, "open v1") }
    defer { sqlite3_close_v2(db) }
    let result = sqlite3_exec(db, productionV1DDL, nil, nil, nil)
    guard result == SQLITE_OK else {
        throw StorageError.sqlite(result, String(cString: sqlite3_errmsg(db)))
    }
}
