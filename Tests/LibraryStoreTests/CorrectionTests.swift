import Foundation
import Testing
@testable import LibraryStore

struct CorrectionFixture {
    let project = UUID(), otherProject = UUID(), root = UUID(), leaf = UUID(), otherLeaf = UUID()
    func state(_ entries: [TimeEntry] = [], active: ActiveTimer? = nil,
               pending: [PendingSleepInterval] = [], revision: Int64 = 1) -> LibrarySnapshot {
        LibrarySnapshot(schemaVersion: 2, revision: revision,
            projects: [Project(id: project, name: "Client", hourlyRate: 1, currencyCode: "EUR"),
                       Project(id: otherProject, name: "Other", hourlyRate: 2, currencyCode: "USD", isArchived: true)],
            tasks: [TaskRecord(id: root, projectID: project, name: "Root"),
                    TaskRecord(id: leaf, projectID: project, parentTaskID: root, name: "Leaf"),
                    TaskRecord(id: otherLeaf, projectID: otherProject, name: "History")],
            entries: entries, activeTimer: active, pendingSleepIntervals: pending)
    }
    func row(_ start: Int64, _ end: Int64?, task: UUID? = nil, id: UUID = UUID()) -> TimeEntry {
        TimeEntry(id: id, taskID: task ?? leaf, startAt: start, endAt: end)
    }
    func replacing(_ state: LibrarySnapshot, entries: [TimeEntry]? = nil, tasks: [TaskRecord]? = nil,
                   projects: [Project]? = nil, revision: Int64? = nil) -> LibrarySnapshot {
        LibrarySnapshot(schemaVersion: state.schemaVersion, revision: revision ?? state.revision,
            projects: projects ?? state.projects, tasks: tasks ?? state.tasks, entries: entries ?? state.entries,
            activeTimer: state.activeTimer, pendingSleepIntervals: state.pendingSleepIntervals)
    }
    func applying(_ mutation: CorrectionMutation, to state: LibrarySnapshot) -> LibrarySnapshot {
        let removed = Set(mutation.before.map(\.id))
        return replacing(state, entries: state.entries.filter { !removed.contains($0.id) } + mutation.after)
    }
    func seed(_ db: isolated Storage, state: LibrarySnapshot) throws {
        func key(_ id: UUID) -> SQLValue { .text(id.uuidString.lowercased()) }
        for p in state.projects {
            try db.runCommand("INSERT INTO projects(id,name,hourly_rate,currency_code,is_archived) VALUES (?,?,?,?,?)",
                bindings: [key(p.id), .text(p.name), .text("1"), .text(p.currencyCode), .integer(p.isArchived ? 1 : 0)], expectedChanges: 1)
        }
        for t in state.tasks {
            try db.runCommand("INSERT INTO tasks(id,project_id,parent_task_id,name) VALUES (?,?,?,?)",
                bindings: [key(t.id), key(t.projectID), t.parentTaskID.map(key) ?? .null, .text(t.name)], expectedChanges: 1)
        }
        for e in state.entries {
            try db.runCommand("INSERT INTO time_entries(id,task_id,start_at,end_at) VALUES (?,?,?,?)",
                bindings: [key(e.id), key(e.taskID), .integer(e.startAt), e.endAt.map(SQLValue.integer) ?? .null], expectedChanges: 1)
        }
        if let a = state.activeTimer {
            try db.runCommand("INSERT INTO active_timer(id,entry_id,checkpoint_at) VALUES (1,?,?)",
                bindings: [key(a.entryID), .integer(a.checkpointAt)], expectedChanges: 1)
        }
    }
}

@Suite struct CorrectionTests {
    func calendar(_ zone: String) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }
    func civil(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> DateComponents {
        DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    @Test func gapsRepeatedChoicesAndStrictInput() throws {
        let amsterdam = calendar("Europe/Amsterdam")
        #expect(CorrectionClock.resolve(civil(2026, 3, 29, 2, 30), calendar: amsterdam) == .nonexistent)
        let repeated = civil(2026, 10, 25, 2, 30, 17)
        guard case let .ambiguous(early, late, earlyOffset, lateOffset) = CorrectionClock.resolve(repeated, calendar: amsterdam) else {
            Issue.record("Repeated time must expose both choices"); return
        }
        #expect(late - early == 3600 && earlyOffset == 7200 && lateOffset == 3600)
        var local = LocalCorrectionTime(components: repeated)
        #expect(throws: CorrectionError.invalidInterval) { try local.resolve(calendar: amsterdam) }
        local.select(early)
        #expect(try local.resolve(calendar: amsterdam) == early)
        local.select(late)
        #expect(try local.resolve(calendar: amsterdam) == late)
        local.components.minute = 31
        #expect(throws: CorrectionError.invalidInterval) { try local.resolve(calendar: amsterdam) }
        for invalid in [civil(2026, 2, 30, 12, 0), civil(2026, 1, 1, 24, 0), civil(2026, 1, 1, 1, 0, 60),
                        DateComponents(year: 2026, month: 1, day: 1, hour: 1, minute: 0),
                        DateComponents(year: 2026, month: 1, day: 1, hour: 1, minute: 0, second: 0, nanosecond: 1)] {
            #expect(CorrectionClock.resolve(invalid, calendar: amsterdam) == .nonexistent)
        }
        var mismatched = civil(2026, 1, 1, 1, 0)
        mismatched.timeZone = TimeZone(secondsFromGMT: 0)
        #expect(CorrectionClock.resolve(mismatched, calendar: amsterdam) == .nonexistent)
        #expect(CorrectionClock.offsetText(20701) == "UTC+05:45:01")
        #expect(CorrectionClock.offsetText(-12600) == "UTC−03:30")
        #expect(CorrectionClock.offsetText(0) == "UTC+00:00")
    }

    @Test func nonHourTransitionsSkippedDaysAndElapsedSeconds() throws {
        let lordHowe = calendar("Australia/Lord_Howe")
        guard case let .ambiguous(early, late, a, b) = CorrectionClock.resolve(civil(2026, 4, 5, 1, 45), calendar: lordHowe) else {
            Issue.record("Lord Howe must repeat thirty minutes"); return
        }
        #expect(late - early == 1800 && a - b == 1800)
        #expect(CorrectionClock.resolve(civil(2026, 10, 4, 2, 15), calendar: lordHowe) == .nonexistent)
        #expect(CorrectionClock.resolve(civil(2011, 12, 30, 12, 0), calendar: calendar("Pacific/Apia")) == .nonexistent)
        let amsterdam = calendar("Europe/Amsterdam")
        let start = try LocalCorrectionTime(components: civil(2026, 3, 29, 0, 0)).resolve(calendar: amsterdam)
        let end = try LocalCorrectionTime(components: civil(2026, 3, 30, 0, 0)).resolve(calendar: amsterdam)
        #expect(try EntryInterval(startAt: start, endAt: end).durationSeconds == 23 * 3600)
        #expect(throws: IntervalError.nonPositiveDuration) { try EntryInterval(startAt: end, endAt: end) }
        #expect(throws: IntervalError.durationOverflow) { try EntryInterval(startAt: .min, endAt: .max) }
    }

    @Test func globalSubtractionAllKindsAdjacencyPathsAndStableIDs() throws {
        let f = CorrectionFixture()
        let left = f.row(0, 20), covered = f.row(20, 30, task: f.otherLeaf), right = f.row(30, 50)
        let state = f.state([right, left, covered])
        let id = UUID()
        let preview = try CorrectionPlanner.preview(.add(id: id, taskID: f.leaf, startAt: 10, endAt: 40), in: state)
        #expect(preview.adjustments.map(\.kind) == [.trimEnd, .delete, .trimStart])
        #expect(preview.adjustments.map(\.before.id) == [left.id, covered.id, right.id])
        #expect(preview.targetPath.text == "Client / Root / Leaf")
        #expect(preview.targetPath.taskIDs == [f.root, f.leaf])
        #expect(preview.adjustments[1].path.text == "Other / History")
        #expect(preview.adjustments[0].retained == [f.row(0, 10, id: left.id)])
        #expect(preview.adjustments[2].retained == [f.row(40, 50, id: right.id)])
        #expect(try CorrectionPlanner.preview(.add(id: UUID(), taskID: f.leaf, startAt: 50, endAt: 60), in: state).adjustments.isEmpty)
        let whole = f.row(0, 100, task: f.otherLeaf)
        let original = f.state([whole])
        let split = try CorrectionPlanner.preview(.add(id: id, taskID: f.leaf, startAt: 20, endAt: 30), in: original)
        #expect(split.adjustments[0].kind == .split)
        #expect(split.adjustments[0].retained[0].id == whole.id)
        let rightID = split.adjustments[0].retained[1].id
        #expect(rightID != whole.id && rightID != id)
        let mutation = try CorrectionMutation.recheck(split, in: original, now: 100)
        #expect(mutation.after.contains { $0.id == rightID && $0.startAt == 30 && $0.endAt == 100 })
        #expect(original == f.state([whole]))
        let collision = f.replacing(original, entries: [f.row(-20, -10, id: rightID), whole])
        #expect(throws: CorrectionError.stalePreview) { try CorrectionMutation.recheck(split, in: collision, now: 100) }
        #expect(throws: CorrectionError.futureEnd) { try CorrectionMutation.recheck(split, in: original, now: 29) }
        for bounds: (Int64, Int64) in [(10, 10), (11, 10), (.min, .max)] {
            #expect(throws: CorrectionError.invalidInterval) {
                try CorrectionPlanner.preview(.add(id: UUID(), taskID: f.leaf, startAt: bounds.0, endAt: bounds.1), in: original)
            }
        }
    }

    @Test func editEligibilityEvidenceAndUnrelatedChanges() throws {
        let f = CorrectionFixture(), id = UUID()
        let source = f.row(10, 20, id: id), state = f.state([f.row(10, 20, id: id)])
        let preview = try CorrectionPlanner.preview(.edit(id: id, taskID: f.leaf, startAt: 11, endAt: 21), in: state)
        #expect(preview.source == source)
        #expect(try CorrectionMutation.recheck(preview, in: f.replacing(state, revision: 99), now: 100).after[0].id == id)
        #expect(throws: CorrectionError.crossProjectMove) {
            try CorrectionPlanner.preview(.edit(id: id, taskID: f.otherLeaf, startAt: 11, endAt: 21), in: state)
        }
        #expect(throws: CorrectionError.unavailableTask) {
            try CorrectionPlanner.preview(.add(id: UUID(), taskID: f.root, startAt: 30, endAt: 40), in: state)
        }
        #expect(try CorrectionPlanner.preview(.add(id: UUID(), taskID: f.otherLeaf, startAt: 30, endAt: 40), in: state).targetPath.projectID == f.otherProject)
        #expect(throws: CorrectionError.missingEntry) {
            try CorrectionPlanner.preview(.edit(id: UUID(), taskID: f.leaf, startAt: 30, endAt: 40), in: state)
        }
        let renamed = state.tasks.map { t in
            TaskRecord(id: t.id, projectID: t.projectID, parentTaskID: t.parentTaskID, name: t.id == f.root ? "Renamed" : t.name)
        }
        #expect(throws: CorrectionError.stalePreview) { try CorrectionMutation.recheck(preview, in: f.replacing(state, tasks: renamed), now: 100) }
        #expect(throws: CorrectionError.stalePreview) {
            try CorrectionMutation.recheck(preview, in: f.replacing(state, entries: [f.row(10, 19, id: id)]), now: 100)
        }
        let plain = try CorrectionPlanner.preview(.add(id: UUID(), taskID: f.leaf, startAt: 30, endAt: 40), in: state)
        #expect(throws: CorrectionError.stalePreview) {
            try CorrectionMutation.recheck(plain, in: f.replacing(state, entries: state.entries + [f.row(35, 36)]), now: 100)
        }
    }

    @Test func openTailStopFreshPreviewAndHarmlessCheckpoint() throws {
        let f = CorrectionFixture(), open = f.row(100, nil)
        let live = f.state([open], active: ActiveTimer(entryID: open.id, checkpointAt: 110))
        let conflicting = try CorrectionPlanner.preview(.add(id: UUID(), taskID: f.otherLeaf, startAt: 200, endAt: 210), in: live)
        #expect(conflicting.runningConflict == open && conflicting.runningPath?.taskIDs == [f.root, f.leaf])
        #expect(conflicting.adjustments.isEmpty)
        #expect(throws: CorrectionError.runningConflict) { try CorrectionMutation.recheck(conflicting, in: live, now: 300) }
        #expect(throws: CorrectionError.runningConflict) {
            try CorrectionPlanner.preview(.edit(id: open.id, taskID: f.leaf, startAt: 90, endAt: 100), in: live)
        }
        let safe = try CorrectionPlanner.preview(.add(id: UUID(), taskID: f.otherLeaf, startAt: 90, endAt: 100), in: live)
        let checkpoint = f.state([open], active: ActiveTimer(entryID: open.id, checkpointAt: 120), revision: 2)
        let result = f.applying(try CorrectionMutation.recheck(safe, in: checkpoint, now: 120), to: checkpoint)
        #expect(result.activeTimer == checkpoint.activeTimer && result.entries.contains(open))
        let stopped = f.state([f.row(100, 120, id: open.id)])
        #expect(throws: CorrectionError.stalePreview) { try CorrectionMutation.recheck(conflicting, in: stopped, now: 300) }
        let fresh = try CorrectionPlanner.preview(conflicting.draft, in: stopped)
        #expect(try CorrectionMutation.recheck(fresh, in: stopped, now: 300).after.count == 1)
    }

    @Test func deletionAndGuardedUndo() throws {
        let f = CorrectionFixture(), whole = f.row(0, 100)
        let before = f.state([whole])
        let shown = try CorrectionPlanner.preview(.add(id: UUID(), taskID: f.otherLeaf, startAt: 20, endAt: 30), in: before)
        let mutation = try CorrectionMutation.recheck(shown, in: before, now: 100)
        let after = f.applying(mutation, to: before), receipt = mutation.receipt
        let undo = try CorrectionMutation.undo(receipt, in: after, now: 100)
        #expect(f.applying(undo, to: after).entries == before.entries)
        let unrelated = f.replacing(after, entries: after.entries + [f.row(110, 120)])
        #expect(try CorrectionMutation.undo(receipt, in: unrelated, now: 120).after == [whole])
        #expect(throws: CorrectionError.undoUnavailable) { try CorrectionMutation.undo(receipt, in: after, now: 99) }
        let changed = f.replacing(after, entries: after.entries.filter { $0.id != shown.draft.entry.id })
        #expect(throws: CorrectionError.undoUnavailable) { try CorrectionMutation.undo(receipt, in: changed, now: 100) }
        let modified = f.replacing(after, entries: after.entries.map { row in
            row.id == shown.draft.entry.id ? f.row(21, 30, task: row.taskID, id: row.id) : row
        })
        #expect(throws: CorrectionError.undoUnavailable) { try CorrectionMutation.undo(receipt, in: modified, now: 100) }
        let deletion = try CorrectionPlanner.previewDeletion(entryID: whole.id, in: before)
        let deleted = try CorrectionMutation.deletion(deletion, in: before)
        #expect(deleted.after.isEmpty)
        let empty = f.state()
        #expect(try CorrectionMutation.undo(deleted.receipt, in: empty, now: 100).after == [whole])
        let reused = f.state([f.row(120, 130, id: whole.id)])
        #expect(throws: CorrectionError.undoUnavailable) { try CorrectionMutation.undo(deleted.receipt, in: reused, now: 130) }
        let closedConflict = f.state([f.row(50, 60)])
        #expect(throws: CorrectionError.undoUnavailable) { try CorrectionMutation.undo(deleted.receipt, in: closedConflict, now: 100) }
        let open = f.row(50, nil)
        let openConflict = f.state([open], active: ActiveTimer(entryID: open.id, checkpointAt: 60))
        #expect(throws: CorrectionError.undoUnavailable) { try CorrectionMutation.undo(deleted.receipt, in: openConflict, now: 100) }
        let moved = empty.tasks.map { t in
            TaskRecord(id: t.id, projectID: t.id == f.leaf ? f.otherProject : t.projectID,
                       parentTaskID: t.id == f.leaf ? nil : t.parentTaskID, name: t.name)
        }
        #expect(throws: CorrectionError.undoUnavailable) { try CorrectionMutation.undo(deleted.receipt, in: f.replacing(empty, tasks: moved), now: 100) }
        let branch = TaskRecord(id: UUID(), projectID: f.project, parentTaskID: f.leaf, name: "New child")
        #expect(throws: CorrectionError.undoUnavailable) {
            try CorrectionMutation.undo(deleted.receipt, in: f.replacing(empty, tasks: empty.tasks + [branch]), now: 100)
        }
        let renamed = empty.tasks.map { t in
            TaskRecord(id: t.id, projectID: t.projectID, parentTaskID: t.parentTaskID, name: t.id == f.root ? "Renamed" : t.name)
        }
        let repriced = empty.projects.map { p in
            Project(id: p.id, name: "Renamed " + p.name, hourlyRate: 123, currencyCode: p.currencyCode, isArchived: p.isArchived)
        }
        #expect(try CorrectionMutation.undo(deleted.receipt, in: f.replacing(empty, tasks: renamed, projects: repriced), now: 100).after == [whole])
        #expect(throws: CorrectionError.deletionChanged) {
            try CorrectionMutation.deletion(deletion, in: f.replacing(before, tasks: renamed))
        }
        #expect(throws: CorrectionError.deletionChanged) {
            try CorrectionMutation.deletion(deletion, in: f.state([f.row(1, 100, id: whole.id)]))
        }
    }

    @Test func atomicPersistenceOneRevisionUndoAndReopen() async throws {
        let f = CorrectionFixture(), whole = f.row(0, 100)
        let directory = URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path, isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await Library.open(at: directory)
        let seeded = try await library.transact(expectedRevision: 0) { db, _ in try f.seed(db, state: f.state([whole])) }
        let shown = try CorrectionPlanner.preview(.add(id: UUID(), taskID: f.otherLeaf, startAt: 20, endAt: 30), in: seeded.snapshot)
        #expect(try await library.snapshot() == seeded.snapshot)
        let committed = try await library.performCorrection(.apply(shown), receipt: nil, expectedRevision: 1, instant: 100)
        #expect(committed.snapshot.revision == 2 && committed.snapshot.entries.count == 3)
        #expect(committed.snapshot.entries.contains(shown.adjustments[0].retained[1]))
        let undone = try await library.performCorrection(.undo, receipt: committed.value, expectedRevision: 2, instant: 100)
        #expect(undone.snapshot.revision == 3 && undone.snapshot.entries == [whole] && undone.value == nil)
        let deletion = try CorrectionPlanner.previewDeletion(entryID: whole.id, in: undone.snapshot)
        let deleted = try await library.performCorrection(.delete(deletion), receipt: nil, expectedRevision: 3, instant: 100)
        #expect(deleted.snapshot.revision == 4 && deleted.snapshot.entries.isEmpty)
        let restored = try await library.performCorrection(.undo, receipt: deleted.value, expectedRevision: 4, instant: 100)
        #expect(restored.snapshot.revision == 5 && restored.snapshot.entries == [whole])
        await library.close()
        let reopened = try await Library.open(at: directory)
        #expect(try await reopened.snapshot() == restored.snapshot)
        await reopened.close()
    }

    @Test func exactDMLPreservesNonconflictingActiveIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("private.sqlite"), f = CorrectionFixture()
        try Storage.createPrivateDatabase(at: url)
        let db = try Storage(privateDatabaseAt: url), open = f.row(100, nil)
        let state = f.state([open], active: ActiveTimer(entryID: open.id, checkpointAt: 110))
        let seeded = try await db.transact(expectedRevision: 0) { db, _ in try f.seed(db, state: state) }
        let shown = try CorrectionPlanner.preview(.add(id: UUID(), taskID: f.otherLeaf, startAt: 90, endAt: 100), in: seeded.snapshot)
        let committed = try await db.transact(expectedRevision: 1) { db, before in
            let mutation = try CorrectionMutation.recheck(shown, in: before, now: 110)
            try mutation.apply(to: db)
            return mutation.receipt
        }
        #expect(committed.snapshot.activeTimer == state.activeTimer)
        #expect(committed.snapshot.entries.contains(open) && committed.snapshot.revision == 2)
        await db.close()
    }

    @Test func lifecycleAuthorizationRejectsEveryReviewState() throws {
        let f = CorrectionFixture(), gate = TimerLifecycleGate(), open = f.row(100, nil)
        let state = f.state([open], active: ActiveTimer(entryID: open.id, checkpointAt: 110))
        #expect(throws: TimerError.reviewRequired) {
            try gate.correctionSample(in: state, ownedEntryID: nil, paused: false, clock: { 110 })
        }
        #expect(throws: TimerError.reviewRequired) {
            try gate.correctionSample(in: state, ownedEntryID: open.id, paused: true, clock: { 110 })
        }
        #expect(throws: TimerError.clockRollback) {
            try gate.correctionSample(in: state, ownedEntryID: open.id, paused: false, clock: { 109 })
        }
        for wake: Int64? in [nil, 60] {
            let pending = PendingSleepInterval(id: UUID(), taskID: f.leaf, sleepAt: 50, wakeAt: wake)
            #expect(throws: TimerError.reviewRequired) {
                try gate.correctionSample(in: f.state(pending: [pending]), ownedEntryID: nil, paused: false, clock: { 110 })
            }
        }
        let generation = gate.latchSleep()
        #expect(throws: TimerError.reviewRequired) {
            try gate.correctionSample(in: state, ownedEntryID: open.id, paused: false, clock: { 110 })
        }
        #expect(gate.state().generation == generation && gate.state().sleeping)
    }

    @Test func exactDMLRollbackAndIndeterminateFaults() async throws {
        for fault in [CommitFault.beforeCommit, .commitRejected, .acknowledgementLost, .rollbackFailure] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("private.sqlite"), f = CorrectionFixture()
            try Storage.createPrivateDatabase(at: url)
            let db = try Storage(privateDatabaseAt: url), whole = f.row(0, 100)
            let seeded = try await db.transact(expectedRevision: 0) { db, _ in try f.seed(db, state: f.state([whole])) }
            let shown = try CorrectionPlanner.preview(.add(id: UUID(), taskID: f.otherLeaf, startAt: 20, endAt: 30), in: seeded.snapshot)
            await #expect(throws: StorageError.self) {
                try await db.transact(expectedRevision: 1, fault: fault) { db, before in
                    let mutation = try CorrectionMutation.recheck(shown, in: before, now: 100)
                    try mutation.apply(to: db)
                    return mutation.receipt
                }
            }
            if fault == .beforeCommit || fault == .commitRejected { #expect(try await db.snapshot() == seeded.snapshot) }
            else { await #expect(throws: StorageError.unavailable) { try await db.snapshot() } }
            await db.close()
            let reopened = try Storage(privateDatabaseAt: url)
            let saved = try await reopened.snapshot()
            #expect(saved.revision == (fault == .acknowledgementLost ? 2 : 1))
            #expect(saved.entries.count == (fault == .acknowledgementLost ? 3 : 1))
            await reopened.close()
        }
    }
}
