import Foundation
import SQLite3
import Testing

@testable import LibraryStore

@Suite struct BudgetTests {
    private let locale = Locale(identifier: "en_US")

    private func snapshot(
        tasks: [TaskRecord], entries: [TimeEntry] = [], timer: ActiveTimer? = nil,
        pending: [PendingSleepInterval] = []
    ) -> LibrarySnapshot {
        LibrarySnapshot(
            schemaVersion: 2, revision: 0,
            projects: [Project(id: budgetProjectID, name: "Client", hourlyRate: 1, currencyCode: "EUR")],
            tasks: tasks, entries: entries, activeTimer: timer, pendingSleepIntervals: pending)
    }

    private func task(
        _ id: UUID = UUID(), parent: UUID? = nil, budget: Int64? = nil,
        band: WarningThreshold = .none
    ) -> TaskRecord {
        TaskRecord(
            id: id, projectID: budgetProjectID, parentTaskID: parent,
            name: id.uuidString, budgetMinutes: budget, lastWarnedThreshold: band)
    }

    @Test func exactLocalizedHoursAndUnchangedDisplay() {
        for text in [
            "", "0", "-1", "+1", "1e2", "NaN", "1x", "1,000", "1.", "1.1.1",
            "0.0001", "0.0025", "153722867280912931", "0.0166666666666666666666666666666666666667"
        ] {
            #expect(BudgetInput.parseHours(text, locale: locale) == nil)
        }
        #expect(BudgetInput.parseHours(" 1.25 ", locale: locale) == 75)
        #expect(BudgetInput.parseHours(".25", locale: locale) == 15)
        #expect(BudgetInput.parseHours("1,25", locale: Locale(identifier: "nl_NL")) == 75)
        #expect(BudgetInput.parseHours("1.25", locale: Locale(identifier: "nl_NL")) == nil)
        #expect(BudgetInput.parseHours("0.05", locale: locale) == 3)
        #expect(BudgetInput.parseHours("153722867280912930.1", locale: locale) == Int64.max - 1)
        #expect(BudgetInput.parseHours("153722867280912930.15", locale: locale) == nil)
        #expect(BudgetInput.parseHours("0001.2500000000000000000000000000000000000000", locale: locale) == 75)
        let original: Int64 = 1
        let displayed = BudgetInput.text(original, locale: locale)
        let submitted =
            displayed == BudgetInput.text(original, locale: locale)
            ? original : BudgetInput.parseHours(displayed, locale: locale)
        #expect(submitted == 1)
        #expect(BudgetInput.text(75, locale: Locale(identifier: "nl_NL")) == "1,25")
    }

    @Test func nearestFrontiersEqualityAndEditedSubtreeAllowance() throws {
        let root = UUID()
        let bridge = UUID()
        let child = UUID()
        let grandchild = UUID()
        let sibling = UUID()
        let rows = [
            task(root, budget: 100), task(bridge, parent: root),
            task(child, parent: bridge, budget: 60), task(grandchild, parent: child, budget: 40),
            task(sibling, parent: root, budget: 40)
        ]
        let value = snapshot(tasks: rows)
        let allocations = try BudgetRules.allocations(in: value)
        #expect(allocations.first { $0.taskID == root }?.allocatedMinutes == 100)
        #expect(allocations.first { $0.taskID == child }?.allocatedMinutes == 40)
        #expect(!SnapshotValidator.violations(in: value).contains { $0.code == .allocation })
        let allowance = try BudgetRules.allowance(
            in: value, projectID: budgetProjectID,
            parentTaskID: bridge, editingTaskID: child)
        #expect(allowance.limitingAncestorID == root)
        #expect(allowance.maximumMinutes == 60)
        #expect(allowance.minimumMinutes == 40)
        let intermediate = try BudgetRules.allowance(
            in: value, projectID: budgetProjectID,
            parentTaskID: root, editingTaskID: bridge)
        #expect(intermediate.maximumMinutes == 60)
        #expect(intermediate.minimumMinutes == 60)
        let fresh = try BudgetRules.allowance(
            in: value, projectID: budgetProjectID,
            parentTaskID: bridge, editingTaskID: nil)
        #expect(fresh.maximumMinutes == 0)
        let lowered = snapshot(tasks: rows.map { $0.id == root ? task(root, budget: 99) : $0 })
        #expect(SnapshotValidator.violations(in: lowered).contains { $0.code == .allocation && $0.recordID == root })
        let removable = snapshot(tasks: [
            task(root, budget: 100), task(child, parent: root, budget: 60),
            task(grandchild, parent: child, budget: 60),
            task(
                sibling, parent: root,
                budget: 40)
        ])
        #expect(!SnapshotValidator.violations(in: removable).contains { $0.code == .allocation })
        let removed = snapshot(tasks: [
            task(root, budget: 100), task(child, parent: root),
            task(grandchild, parent: child, budget: 60),
            task(
                sibling, parent: root,
                budget: 40)
        ])
        #expect(try BudgetRules.allocations(in: removed).first { $0.taskID == root }?.allocatedMinutes == 100)
        #expect(!SnapshotValidator.violations(in: removed).contains { $0.code == .allocation })
        let huge = snapshot(tasks: [
            task(root, budget: .max), task(child, parent: root, budget: .max),
            task(sibling, parent: root, budget: .max)
        ])
        #expect(
            try BudgetRules.allocations(in: huge).first { $0.taskID == root }?.allocatedMinutes == Decimal(Int64.max)
                * 2)
    }

    @Test func lifetimeRollupCheckpointZeroAndPendingExclusion() throws {
        let root = UUID()
        let bridge = UUID()
        let leaf = UUID()
        let other = UUID()
        let openID = UUID()
        let rows = [task(root), task(bridge, parent: root), task(leaf, parent: bridge), task(other, parent: root)]
        let entries = [
            TimeEntry(id: UUID(), taskID: leaf, startAt: -1000, endAt: -900),
            TimeEntry(id: UUID(), taskID: other, startAt: -800, endAt: -780),
            TimeEntry(id: openID, taskID: leaf, startAt: 0, endAt: nil)
        ]
        let pending = [PendingSleepInterval(id: UUID(), taskID: leaf, sleepAt: -500, wakeAt: -400)]
        let value = snapshot(
            tasks: rows, entries: entries,
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
        #expect(BudgetRules.band(used: 47, budget: 1) == .none)
        #expect(BudgetRules.band(used: 48, budget: 1) == .eighty)
        #expect(BudgetRules.band(used: 59, budget: 1) == .eighty)
        #expect(BudgetRules.band(used: 60, budget: 1) == .hundred)
        #expect(BudgetRules.band(used: 1000, budget: nil) == .none)
        let maximum = Decimal(Int64.max) * 60
        let eighty = Decimal(Int64.max) * 48
        #expect(BudgetRules.band(used: eighty - 1, budget: .max) == .none)
        #expect(BudgetRules.band(used: eighty, budget: .max) == .eighty)
        #expect(BudgetRules.band(used: maximum - 1, budget: .max) == .eighty)
        #expect(BudgetRules.band(used: maximum, budget: .max) == .hundred)
        let timer = UUID()
        let right = UUID()
        let entryID = UUID()
        let values = [
            snapshot(tasks: [task(timer, parent: right), task(right, parent: timer)]),
            snapshot(tasks: [task(timer), task(timer)]), snapshot(tasks: [task(timer, parent: right)]),
            snapshot(
                tasks: [task(timer)],
                entries: [
                    TimeEntry(
                        id: entryID, taskID: timer, startAt: 5,
                        endAt: 4)
                ]),
            snapshot(
                tasks: [task(timer)],
                entries: [
                    TimeEntry(
                        id: entryID, taskID: timer, startAt: .min,
                        endAt: .max)
                ]),
            snapshot(
                tasks: [task(timer)],
                entries: [
                    TimeEntry(
                        id: entryID, taskID: timer, startAt: 0,
                        endAt: nil)
                ]),
            snapshot(
                tasks: [task(timer), task(right, parent: timer)],
                entries: [TimeEntry(id: entryID, taskID: timer, startAt: 0, endAt: 1)])
        ]
        for value in values {
            #expect(throws: LibraryError.self) { try BudgetRules.allocations(in: value) }
            #expect(throws: LibraryError.self) { try BudgetRules.usage(in: value) }
        }
        let incoherent = snapshot(tasks: [task(timer, budget: 100, band: .hundred)])
        #expect(SnapshotValidator.violations(in: incoherent) == [Violation(.warning, timer)])
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
        let root = UUID()
        let leaf = UUID()
        let entry = UUID()
        let key: @Sendable (UUID) -> SQLValue = { .text($0.uuidString.lowercased()) }
        let first = try await store.transact(expectedRevision: 0) { database, _ in
            try database.runCommand(
                "INSERT INTO projects(id,name,hourly_rate,currency_code) VALUES (?,?,?,?)",
                bindings: [key(budgetProjectID), .text("Client"), .text("1"), .text("EUR")], expectedChanges: 1)
            try database.runCommand(
                "INSERT INTO tasks(id,project_id,parent_task_id,name,budget_minutes) VALUES (?,?,NULL,?,?)",
                bindings: [key(root), key(budgetProjectID), .text("Root"), .integer(100)], expectedChanges: 1)
            try database.runCommand(
                "INSERT INTO tasks(id,project_id,parent_task_id,name,budget_minutes) VALUES (?,?,?,?,?)",
                bindings: [key(leaf), key(budgetProjectID), key(root), .text("Leaf"), .integer(100)],
                expectedChanges: 1)
            try database.runCommand(
                "INSERT INTO time_entries(id,task_id,start_at,end_at) VALUES (?,?,0,NULL)",
                bindings: [key(entry), key(leaf)], expectedChanges: 1)
            try database.runCommand(
                "INSERT INTO active_timer(id,entry_id,checkpoint_at) VALUES (1,?,0)",
                bindings: [key(entry)], expectedChanges: 1)
        }.snapshot
        #expect(first.revision == 1)
        let crossed = try await store.transact(expectedRevision: 1) { database, before in
            try TimerTransition.checkpoint(before: before, entryID: entry, instant: 4800, to: database)
            try database.runCommand(
                "UPDATE tasks SET name=?,budget_minutes=? WHERE id=?",
                bindings: [.text("Renamed"), .integer(80), key(leaf)], expectedChanges: 1)
        }.snapshot
        #expect(crossed.revision == 2)
        #expect(crossed.activeTimer?.checkpointAt == 4800)
        #expect(crossed.tasks.first { $0.id == root }?.lastWarnedThreshold == .eighty)
        #expect(crossed.tasks.first { $0.id == leaf }?.lastWarnedThreshold == .hundred)
        for fault in [CommitFault.beforeCommit, .commitRejected] {
            do {
                _ = try await store.transact(expectedRevision: 2, fault: fault) { database, _ in
                    try database.runCommand(
                        "UPDATE tasks SET name='Unpublished' WHERE id=?", bindings: [key(leaf)], expectedChanges: 1)
                }
                Issue.record("fault unexpectedly succeeded")
            } catch {}
            #expect(try await store.snapshot() == crossed)
        }
        do {
            _ = try await store.transact(expectedRevision: 2) { database, before in
                try TimerTransition.checkpoint(before: before, entryID: entry, instant: 5400, to: database)
                try database.runCommand(
                    "UPDATE tasks SET name='Invalid',budget_minutes=101 WHERE id=?",
                    bindings: [key(leaf)], expectedChanges: 1)
            }
            Issue.record("allocation unexpectedly succeeded")
        } catch LibraryError.invalid(let errors) { #expect(errors.contains { $0.code == .allocation }) }
        #expect(try await store.snapshot() == crossed)
        let rearmed = try await store.transact(expectedRevision: 2) { database, _ in
            try database.runCommand(
                "UPDATE tasks SET budget_minutes=200 WHERE id=?", bindings: [key(root)], expectedChanges: 1)
            try database.runCommand(
                "UPDATE tasks SET budget_minutes=NULL WHERE id=?", bindings: [key(leaf)], expectedChanges: 1)
        }.snapshot
        #expect(rearmed.tasks.allSatisfy { $0.lastWarnedThreshold == .none })
        let overrun = try await store.transact(expectedRevision: 3) { database, before in
            try TimerTransition.checkpoint(before: before, entryID: entry, instant: 15000, to: database)
        }.snapshot
        #expect(overrun.activeTimer?.checkpointAt == 15000)
        #expect(overrun.tasks.first { $0.id == root }?.lastWarnedThreshold == .hundred)
        let corrected = try await store.transact(expectedRevision: 4) { database, _ in
            try database.runCommand("DELETE FROM active_timer WHERE id=1", bindings: [], expectedChanges: 1)
            try database.runCommand(
                "UPDATE time_entries SET end_at=1200 WHERE id=?", bindings: [key(entry)], expectedChanges: 1)
            try database.runCommand(
                "UPDATE tasks SET parent_task_id=NULL WHERE id=?", bindings: [key(leaf)], expectedChanges: 1)
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
            let update = sqlite3_exec(
                database,
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
