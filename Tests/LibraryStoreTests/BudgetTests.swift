import Foundation
import SQLite3
import Testing
@testable import LibraryStore

@Suite struct BudgetTests {
    private let locale = Locale(identifier: "en_US")

    private func snapshot(tasks: [TaskRecord], entries: [TimeEntry] = [], timer: ActiveTimer? = nil,
                          pending: [PendingSleepInterval] = []) -> LibrarySnapshot {
        LibrarySnapshot(schemaVersion: 1, revision: 0,
            projects: [Project(id: budgetProjectID, name: "Client", hourlyRate: 1, currencyCode: "EUR")],
            tasks: tasks, entries: entries, activeTimer: timer, pendingSleepIntervals: pending)
    }

    private func task(_ id: UUID = UUID(), parent: UUID? = nil, budget: Int64? = nil,
                      band: WarningThreshold = .none) -> TaskRecord {
        TaskRecord(id: id, projectID: budgetProjectID, parentTaskID: parent,
                   name: id.uuidString, budgetSeconds: budget, lastWarnedThreshold: band)
    }

    @Test func exactLocalizedHoursAndUnchangedDisplay() {
        for text in ["", "0", "-1", "+1", "1e2", "NaN", "1x", "1,000", "1.", "1.1.1",
                     "0.0001", "2562047788015216", "0.00027777777777777777777777777777777777777777"] {
            #expect(BudgetInput.parseHours(text, locale: locale) == nil)
        }
        #expect(BudgetInput.parseHours(" 1.25 ", locale: locale) == 4500)
        #expect(BudgetInput.parseHours(".25", locale: locale) == 900)
        #expect(BudgetInput.parseHours("1,25", locale: Locale(identifier: "nl_NL")) == 4500)
        #expect(BudgetInput.parseHours("1.25", locale: Locale(identifier: "nl_NL")) == nil)
        #expect(BudgetInput.parseHours("0.0025", locale: locale) == 9)
        #expect(BudgetInput.parseHours("0001.2500000000000000000000000000000000000000", locale: locale) == 4500)
        let original: Int64 = 1
        let displayed = BudgetInput.text(original, locale: locale)
        let submitted = displayed == BudgetInput.text(original, locale: locale)
            ? original : BudgetInput.parseHours(displayed, locale: locale)
        #expect(submitted == 1)
        #expect(BudgetInput.text(4500, locale: Locale(identifier: "nl_NL")) == "1,25")
    }

    @Test func nearestFrontiersEqualityAndEditedSubtreeAllowance() throws {
        let root = UUID(), bridge = UUID(), child = UUID(), grandchild = UUID(), sibling = UUID()
        let rows = [task(root, budget: 100), task(bridge, parent: root),
                    task(child, parent: bridge, budget: 60), task(grandchild, parent: child, budget: 40),
                    task(sibling, parent: root, budget: 40)]
        let value = snapshot(tasks: rows)
        let allocations = try BudgetRules.allocations(in: value)
        #expect(allocations.first { $0.taskID == root }?.allocatedSeconds == 100)
        #expect(allocations.first { $0.taskID == child }?.allocatedSeconds == 40)
        #expect(!SnapshotValidator.violations(in: value).contains { $0.code == .allocation })
        let allowance = try BudgetRules.allowance(in: value, projectID: budgetProjectID,
                                                 parentTaskID: bridge, editingTaskID: child)
        #expect(allowance.limitingAncestorID == root)
        #expect(allowance.maximumSeconds == 60)
        #expect(allowance.minimumSeconds == 40)
        let intermediate = try BudgetRules.allowance(in: value, projectID: budgetProjectID,
                                                    parentTaskID: root, editingTaskID: bridge)
        #expect(intermediate.maximumSeconds == 60)
        #expect(intermediate.minimumSeconds == 60)
        let fresh = try BudgetRules.allowance(in: value, projectID: budgetProjectID,
                                             parentTaskID: bridge, editingTaskID: nil)
        #expect(fresh.maximumSeconds == 0)
        let lowered = snapshot(tasks: rows.map { $0.id == root ? task(root, budget: 99) : $0 })
        #expect(SnapshotValidator.violations(in: lowered).contains { $0.code == .allocation && $0.recordID == root })
        let removable = snapshot(tasks: [task(root, budget: 100), task(child, parent: root, budget: 60),
                                         task(grandchild, parent: child, budget: 60), task(sibling, parent: root, budget: 40)])
        #expect(!SnapshotValidator.violations(in: removable).contains { $0.code == .allocation })
        let removed = snapshot(tasks: [task(root, budget: 100), task(child, parent: root),
                                      task(grandchild, parent: child, budget: 60), task(sibling, parent: root, budget: 40)])
        #expect(try BudgetRules.allocations(in: removed).first { $0.taskID == root }?.allocatedSeconds == 100)
        #expect(!SnapshotValidator.violations(in: removed).contains { $0.code == .allocation })
        let huge = snapshot(tasks: [task(root, budget: .max), task(child, parent: root, budget: .max),
                                   task(sibling, parent: root, budget: .max)])
        #expect(try BudgetRules.allocations(in: huge).first { $0.taskID == root }?.allocatedSeconds == Decimal(Int64.max) * 2)
    }

    @Test func lifetimeRollupCheckpointZeroAndPendingExclusion() throws {
        let root = UUID(), bridge = UUID(), leaf = UUID(), other = UUID(), openID = UUID()
        let rows = [task(root), task(bridge, parent: root), task(leaf, parent: bridge), task(other, parent: root)]
        let entries = [TimeEntry(id: UUID(), taskID: leaf, startAt: -1000, endAt: -900),
                       TimeEntry(id: UUID(), taskID: other, startAt: -800, endAt: -780),
                       TimeEntry(id: openID, taskID: leaf, startAt: 0, endAt: nil)]
        let pending = [PendingSleepInterval(id: UUID(), taskID: leaf, sleepAt: -500, wakeAt: -400)]
        let value = snapshot(tasks: rows, entries: entries,
                             timer: ActiveTimer(entryID: openID, checkpointAt: 30), pending: pending)
        let totals = try BudgetRules.usage(in: value)
        #expect(totals[leaf] == 130)
        #expect(totals[bridge] == 130)
        #expect(totals[root] == 150)
        #expect(try BudgetRules.usage(in: value, liveEnd: 40)[root] == 160)
        let zero = snapshot(tasks: rows, entries: [entries[2]], timer: ActiveTimer(entryID: openID, checkpointAt: 0))
        #expect(try BudgetRules.usage(in: zero)[root] == 0)
        #expect(throws: LibraryError.self) { try BudgetRules.usage(in: value, liveEnd: 29) }
    }

    @Test func exactBandsAndMalformedSnapshotsFailClosed() throws {
        #expect(BudgetRules.band(used: 0, budget: 1) == .none)
        #expect(BudgetRules.band(used: 1, budget: 1) == .hundred)
        #expect(BudgetRules.band(used: 79, budget: 100) == .none)
        #expect(BudgetRules.band(used: 80, budget: 100) == .eighty)
        #expect(BudgetRules.band(used: 99, budget: 100) == .eighty)
        #expect(BudgetRules.band(used: 100, budget: 100) == .hundred)
        #expect(BudgetRules.band(used: 1000, budget: nil) == .none)
        let eighty = (Int64.max / 5) * 4 + ((Int64.max % 5) * 4 + 4) / 5
        #expect(BudgetRules.band(used: Decimal(eighty - 1), budget: .max) == .none)
        #expect(BudgetRules.band(used: Decimal(eighty), budget: .max) == .eighty)
        #expect(BudgetRules.band(used: Decimal(Int64.max), budget: .max) == .hundred)
        let a = UUID(), b = UUID(), entryID = UUID()
        let values = [snapshot(tasks: [task(a, parent: b), task(b, parent: a)]),
                      snapshot(tasks: [task(a), task(a)]), snapshot(tasks: [task(a, parent: b)]),
                      snapshot(tasks: [task(a)], entries: [TimeEntry(id: entryID, taskID: a, startAt: 5, endAt: 4)]),
                      snapshot(tasks: [task(a)], entries: [TimeEntry(id: entryID, taskID: a, startAt: .min, endAt: .max)]),
                      snapshot(tasks: [task(a)], entries: [TimeEntry(id: entryID, taskID: a, startAt: 0, endAt: nil)]),
                      snapshot(tasks: [task(a), task(b, parent: a)],
                               entries: [TimeEntry(id: entryID, taskID: a, startAt: 0, endAt: 1)])]
        for value in values {
            #expect(throws: LibraryError.self) { try BudgetRules.allocations(in: value) }
            #expect(throws: LibraryError.self) { try BudgetRules.usage(in: value) }
        }
        let incoherent = snapshot(tasks: [task(a, budget: 100, band: .hundred)])
        #expect(SnapshotValidator.violations(in: incoherent) == [Violation(.warning, a)])
        #expect(throws: LibraryError.self) { try SnapshotValidator.validate(incoherent) }
    }
}

private let budgetProjectID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

extension BudgetTests {
    @Test func commonTailPersistsRearmsAndRollsBackEveryBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("budget.sqlite")
        try Storage.createPrivateDatabase(at: url)
        let store = try Storage(privateDatabaseAt: url)
        let root = UUID(), leaf = UUID(), entry = UUID()
        let key: @Sendable (UUID) -> SQLValue = { .text($0.uuidString.lowercased()) }
        let first = try await store.transact(expectedRevision: 0) { db, _ in
            try db.runCommand("INSERT INTO projects(id,name,hourly_rate,currency_code) VALUES (?,?,?,?)",
                bindings: [key(budgetProjectID), .text("Client"), .text("1"), .text("EUR")], expectedChanges: 1)
            try db.runCommand("INSERT INTO tasks(id,project_id,parent_task_id,name,budget_seconds) VALUES (?,?,NULL,?,?)",
                bindings: [key(root), key(budgetProjectID), .text("Root"), .integer(100)], expectedChanges: 1)
            try db.runCommand("INSERT INTO tasks(id,project_id,parent_task_id,name,budget_seconds) VALUES (?,?,?,?,?)",
                bindings: [key(leaf), key(budgetProjectID), key(root), .text("Leaf"), .integer(100)], expectedChanges: 1)
            try db.runCommand("INSERT INTO time_entries(id,task_id,start_at,end_at) VALUES (?,?,0,NULL)",
                bindings: [key(entry), key(leaf)], expectedChanges: 1)
            try db.runCommand("INSERT INTO active_timer(id,entry_id,checkpoint_at) VALUES (1,?,0)",
                bindings: [key(entry)], expectedChanges: 1)
        }.snapshot
        #expect(first.revision == 1)
        let crossed = try await store.transact(expectedRevision: 1) { db, before in
            try TimerTransition.checkpoint(before: before, entryID: entry, instant: 80, to: db)
            try db.runCommand("UPDATE tasks SET name=?,budget_seconds=? WHERE id=?",
                bindings: [.text("Renamed"), .integer(80), key(leaf)], expectedChanges: 1)
        }.snapshot
        #expect(crossed.revision == 2)
        #expect(crossed.activeTimer?.checkpointAt == 80)
        #expect(crossed.tasks.first { $0.id == root }?.lastWarnedThreshold == .eighty)
        #expect(crossed.tasks.first { $0.id == leaf }?.lastWarnedThreshold == .hundred)
        for fault in [CommitFault.beforeCommit, .commitRejected] {
            do {
                _ = try await store.transact(expectedRevision: 2, fault: fault) { db, _ in
                    try db.runCommand("UPDATE tasks SET name='Unpublished' WHERE id=?", bindings: [key(leaf)], expectedChanges: 1)
                }
                Issue.record("fault unexpectedly succeeded")
            } catch { }
            #expect(try await store.snapshot() == crossed)
        }
        do {
            _ = try await store.transact(expectedRevision: 2) { db, before in
                try TimerTransition.checkpoint(before: before, entryID: entry, instant: 90, to: db)
                try db.runCommand("UPDATE tasks SET name='Invalid',budget_seconds=101 WHERE id=?",
                    bindings: [key(leaf)], expectedChanges: 1)
            }
            Issue.record("allocation unexpectedly succeeded")
        } catch LibraryError.invalid(let errors) { #expect(errors.contains { $0.code == .allocation }) }
        #expect(try await store.snapshot() == crossed)
        let rearmed = try await store.transact(expectedRevision: 2) { db, _ in
            try db.runCommand("UPDATE tasks SET budget_seconds=200 WHERE id=?", bindings: [key(root)], expectedChanges: 1)
            try db.runCommand("UPDATE tasks SET budget_seconds=NULL WHERE id=?", bindings: [key(leaf)], expectedChanges: 1)
        }.snapshot
        #expect(rearmed.tasks.allSatisfy { $0.lastWarnedThreshold == .none })
        let overrun = try await store.transact(expectedRevision: 3) { db, before in
            try TimerTransition.checkpoint(before: before, entryID: entry, instant: 250, to: db)
        }.snapshot
        #expect(overrun.activeTimer?.checkpointAt == 250)
        #expect(overrun.tasks.first { $0.id == root }?.lastWarnedThreshold == .hundred)
        let corrected = try await store.transact(expectedRevision: 4) { db, _ in
            try db.runCommand("DELETE FROM active_timer WHERE id=1", bindings: [], expectedChanges: 1)
            try db.runCommand("UPDATE time_entries SET end_at=20 WHERE id=?", bindings: [key(entry)], expectedChanges: 1)
            try db.runCommand("UPDATE tasks SET parent_task_id=NULL WHERE id=?", bindings: [key(leaf)], expectedChanges: 1)
        }.snapshot
        #expect(corrected.tasks.allSatisfy { $0.lastWarnedThreshold == .none })
        await store.close()
        let reopened = try Storage(privateDatabaseAt: url)
        #expect(try await reopened.snapshot() == corrected)
        await reopened.close()
        do {
            var database: OpaquePointer?
            let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil)
            guard result == SQLITE_OK, let database else { throw StorageError.sqlite(result, "open") }
            defer { sqlite3_close_v2(database) }
            let update = sqlite3_exec(database,
                "UPDATE tasks SET last_warned_threshold=100 WHERE id='\(root.uuidString.lowercased())'", nil, nil, nil)
            guard update == SQLITE_OK else {
                throw StorageError.sqlite(update, String(cString: sqlite3_errmsg(database)))
            }
        }
        let bytes = try Data(contentsOf: url)
        #expect(throws: LibraryError.self) { _ = try Storage(privateDatabaseAt: url) }
        #expect(try Data(contentsOf: url) == bytes)
    }
}
