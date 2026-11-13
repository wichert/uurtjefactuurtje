import Foundation
import Testing

@testable import LibraryStore

private struct SleepFixture: Sendable {
    let project = UUID(), otherProject = UUID(), root = UUID(), leaf = UUID(), otherLeaf = UUID()
    func state(
        _ entries: [TimeEntry] = [], active: ActiveTimer? = nil,
        pending: [PendingSleepInterval] = [], archived: Bool = false,
        renamed: Bool = false
    ) -> LibrarySnapshot {
        LibrarySnapshot(
            schemaVersion: 2, revision: 0,
            projects: [
                Project(id: project, name: "Client", hourlyRate: 1, currencyCode: "EUR", isArchived: archived),
                Project(id: otherProject, name: "Other", hourlyRate: 2, currencyCode: "USD")
            ],
            tasks: [
                TaskRecord(id: root, projectID: project, name: "Root"),
                TaskRecord(id: leaf, projectID: project, parentTaskID: root, name: renamed ? "Changed" : "Leaf"),
                TaskRecord(id: otherLeaf, projectID: otherProject, name: "Other")
            ],
            entries: entries, activeTimer: active, pendingSleepIntervals: pending)
    }
    func row(_ start: Int64, _ end: Int64?, task: UUID? = nil, id: UUID = UUID()) -> TimeEntry {
        TimeEntry(id: id, taskID: task ?? leaf, startAt: start, endAt: end)
    }
    func pending(
        _ start: Int64 = 20, _ end: Int64? = 30, task: UUID? = nil,
        id: UUID = UUID()
    ) -> PendingSleepInterval {
        PendingSleepInterval(id: id, taskID: task ?? leaf, sleepAt: start, wakeAt: end)
    }
    func applying(_ mutation: TimeReviewMutation, to state: LibrarySnapshot) -> LibrarySnapshot {
        let removed = Set(mutation.entries.before.map(\.id))
        return LibrarySnapshot(
            schemaVersion: state.schemaVersion, revision: state.revision + 1,
            projects: state.projects, tasks: state.tasks,
            entries: state.entries.filter { !removed.contains($0.id) } + mutation.entries.after,
            activeTimer: mutation.restoreActive ?? (mutation.removeActive == nil ? state.activeTimer : nil),
            pendingSleepIntervals: state.pendingSleepIntervals.filter { $0.id != mutation.removePending?.id }
                + (mutation.restorePending.map { [$0] } ?? []))
    }
    func seed(_ database: isolated Storage, state: LibrarySnapshot) throws {
        func key(_ id: UUID) -> SQLValue { .text(id.uuidString.lowercased()) }
        for project in state.projects {
            try database.runCommand(
                "INSERT INTO projects(id,name,hourly_rate,currency_code,is_archived) VALUES (?,?,?,?,?)",
                bindings: [
                    key(project.id), .text(project.name), .text("1"), .text(project.currencyCode),
                    .integer(project.isArchived ? 1 : 0)
                ], expectedChanges: 1)
        }
        for tracker in state.tasks {
            try database.runCommand(
                "INSERT INTO tasks(id,project_id,parent_task_id,name) VALUES (?,?,?,?)",
                bindings: [
                    key(tracker.id), key(tracker.projectID), tracker.parentTaskID.map(key) ?? .null,
                    .text(tracker.name)
                ], expectedChanges: 1)
        }
        for entry in state.entries {
            try database.runCommand(
                "INSERT INTO time_entries(id,task_id,start_at,end_at) VALUES (?,?,?,?)",
                bindings: [
                    key(entry.id), key(entry.taskID), .integer(entry.startAt),
                    entry.endAt.map(SQLValue.integer) ?? .null
                ], expectedChanges: 1)
        }
        if let timer = state.activeTimer {
            try database.runCommand(
                "INSERT INTO active_timer(id,entry_id,checkpoint_at) VALUES (1,?,?)",
                bindings: [key(timer.entryID), .integer(timer.checkpointAt)], expectedChanges: 1)
        }
        for project in state.pendingSleepIntervals {
            try database.runCommand(
                "INSERT INTO pending_sleep_intervals(id,task_id,sleep_at,wake_at) VALUES (?,?,?,?)",
                bindings: [
                    key(project.id), key(project.taskID), .integer(project.sleepAt),
                    project.wakeAt.map(SQLValue.integer) ?? .null
                ], expectedChanges: 1)
        }
    }
}

@Suite struct SleepTests {
    @Test func exactKnownEndExplicitUnknownAndInvalidBounds() throws {
        let fixture = SleepFixture()
        let known = fixture.pending()
        let unknown = fixture.pending(40, nil)
        let state = fixture.state(pending: [known, unknown])
        let included = try SleepPlanner.include(known, endAt: nil, in: state)
        #expect(included.correction.draft.entry.startAt == 20 && included.correction.draft.entry.endAt == 30)
        #expect(throws: SleepError.invalidEnd) { try SleepPlanner.include(known, endAt: 31, in: state) }
        #expect(throws: SleepError.missingEnd) { try SleepPlanner.include(unknown, endAt: nil, in: state) }
        for end: Int64 in [39, 40] {
            #expect(throws: SleepError.invalidEnd) { try SleepPlanner.include(unknown, endAt: end, in: state) }
        }
        let huge = fixture.pending(.min, nil)
        #expect(throws: SleepError.invalidEnd) {
            try SleepPlanner.include(
                huge, endAt: .max,
                in: fixture.state(pending: [huge]))
        }
        let explicit = try SleepPlanner.include(unknown, endAt: 50, in: state)
        #expect(throws: CorrectionError.futureEnd) {
            try TimeReviewMutation.plan(.include(explicit), receipt: nil, in: state, now: 49)
        }
        let missing = fixture.pending(task: UUID())
        #expect(throws: SleepError.staleReview) { try SleepPlanner.skip(missing, in: state) }
        let skipped = try TimeReviewMutation.plan(
            .skip(SleepPlanner.skip(known, in: state)), receipt: nil, in: state,
            now: 50)
        let result = fixture.applying(skipped.mutation, to: state)
        #expect(result.entries.isEmpty && result.pendingSleepIntervals == [unknown])
        #expect(try TimeReviewMutation.undo(#require(skipped.receipt), in: result, now: 50).restorePending == known)
    }

    @Test func globalAdjustmentsStableIdentitiesAndStaleEvidence() throws {
        let fixture = SleepFixture()
        let pending = fixture.pending(20, 80)
        let rows = [fixture.row(0, 30), fixture.row(40, 50, task: fixture.otherLeaf), fixture.row(70, 100)]
        let state = fixture.state(rows, pending: [pending])
        let shown = try SleepPlanner.include(pending, endAt: nil, in: state)
        #expect(shown.correction.adjustments.count == 3)
        let planned = try TimeReviewMutation.plan(.include(shown), receipt: nil, in: state, now: 100)
        let result = fixture.applying(planned.mutation, to: state)
        #expect(result.entries.contains(shown.correction.draft.entry))
        #expect(result.entries.contains(fixture.row(0, 20, id: rows[0].id)))
        #expect(result.entries.contains(fixture.row(80, 100, id: rows[2].id)))
        #expect(!result.entries.contains(where: { $0.id == rows[1].id }))
        #expect(throws: SleepError.staleReview) {
            try TimeReviewMutation.plan(
                .include(shown), receipt: nil,
                in: fixture.state(
                    rows, pending: [pending],
                    renamed: true), now: 100)
        }
        let whole = fixture.row(0, 100)
        let splitState = fixture.state([whole], pending: [pending])
        let split = try SleepPlanner.include(pending, endAt: nil, in: splitState)
        let right = try #require(split.correction.adjustments.first?.retained.last)
        let unrelated = fixture.row(110, 120, task: fixture.otherLeaf)
        let accepted = try TimeReviewMutation.plan(
            .include(split), receipt: nil,
            in: fixture.state([whole, unrelated], pending: [pending]), now: 120)
        #expect(accepted.mutation.entries.after.contains(right))
        #expect(throws: CorrectionError.stalePreview) {
            try TimeReviewMutation.plan(
                .include(split), receipt: nil,
                in: fixture.state([fixture.row(0, 99, id: whole.id)], pending: [pending]), now: 120)
        }
        let undone = try TimeReviewMutation.undo(
            #require(accepted.receipt),
            in: fixture.applying(accepted.mutation, to: fixture.state([whole, unrelated], pending: [pending])),
            now: 120)
        #expect(undone.entries.after == [whole] && undone.restorePending == pending)
    }

    @Test func runningTailRequiresStopAndFreshReview() throws {
        let fixture = SleepFixture()
        let pending = fixture.pending(20, 40)
        let open = fixture.row(30, nil)
        let running = fixture.state([open], active: ActiveTimer(entryID: open.id, checkpointAt: 35), pending: [pending])
        let shown = try SleepPlanner.include(pending, endAt: nil, in: running)
        #expect(shown.correction.runningConflict == open)
        #expect(throws: CorrectionError.runningConflict) {
            try TimeReviewMutation.plan(.include(shown), receipt: nil, in: running, now: 50)
        }
        let stopped = fixture.state([fixture.row(30, 50, id: open.id)], pending: [pending])
        #expect(throws: CorrectionError.stalePreview) {
            try TimeReviewMutation.plan(.include(shown), receipt: nil, in: stopped, now: 50)
        }
        let fresh = try SleepPlanner.include(pending, endAt: nil, in: stopped)
        let plan = try TimeReviewMutation.plan(.include(fresh), receipt: nil, in: stopped, now: 50)
        #expect(plan.mutation.entries.after.contains(fixture.row(40, 50, id: open.id)))
        let postWake = fixture.row(40, nil)
        let safe = fixture.state(
            [postWake], active: ActiveTimer(entryID: postWake.id, checkpointAt: 50),
            pending: [pending])
        let safePlan = try TimeReviewMutation.plan(
            .include(SleepPlanner.include(pending, endAt: nil, in: safe)),
            receipt: nil, in: safe, now: 50)
        #expect(fixture.applying(safePlan.mutation, to: safe).activeTimer == safe.activeTimer)
        #expect(!safePlan.mutation.entries.before.contains(postWake))
    }

    @Test func interruptionUsesCheckpointIdentityDiscardAndActualNow() throws {
        let fixture = SleepFixture()
        let open = fixture.row(10, nil)
        let active = ActiveTimer(
            entryID: open.id,
            checkpointAt: 30)
        let state = fixture.state([open], active: active)
        let shown = try SleepPlanner.interruption(endAt: active.checkpointAt, in: state)
        let plan = try TimeReviewMutation.plan(.resolveInterruption(shown), receipt: nil, in: state, now: 30)
        let saved = fixture.applying(plan.mutation, to: state)
        #expect(saved.activeTimer == nil && saved.entries == [fixture.row(10, 30, id: open.id)])
        #expect(throws: CorrectionError.futureEnd) {
            try TimeReviewMutation.plan(.resolveInterruption(shown), receipt: nil, in: state, now: 29)
        }
        #expect(throws: SleepError.invalidEnd) { try SleepPlanner.interruption(endAt: 9, in: state) }
        for end: Int64? in [nil, 10] {
            let discard = try TimeReviewMutation.plan(
                .resolveInterruption(
                    SleepPlanner.interruption(
                        endAt: end,
                        in: state)),
                receipt: nil, in: state, now: 30)
            #expect(fixture.applying(discard.mutation, to: state).entries.isEmpty)
            let undo = try TimeReviewMutation.undo(
                #require(discard.receipt),
                in: fixture.applying(discard.mutation, to: state), now: 30)
            #expect(undo.restoreActive == active && undo.entries.after == [open])
        }
        let changed = fixture.state([open], active: ActiveTimer(entryID: open.id, checkpointAt: 31))
        #expect(throws: SleepError.staleReview) {
            try TimeReviewMutation.plan(.resolveInterruption(shown), receipt: nil, in: changed, now: 40)
        }
        #expect(throws: SleepError.staleReview) {
            try TimeReviewMutation.plan(
                .resolveInterruption(shown), receipt: nil,
                in: fixture.state([open], active: active, renamed: true), now: 40)
        }
        let pending = fixture.pending()
        let archived = fixture.state(pending: [pending], archived: true)
        #expect(
            try TimeReviewMutation.plan(
                .include(SleepPlanner.include(pending, endAt: nil, in: archived)),
                receipt: nil, in: archived, now: 100
            ).mutation.entries.after.count == 1)
    }

    @Test func undoRejectsReusedIDsOwnersSingletonsOpenTailsAndFutureRows() throws {
        let fixture = SleepFixture()
        let pending = fixture.pending()
        let row = fixture.row(0, 100)
        let state = fixture.state([row], pending: [pending])
        let plan = try TimeReviewMutation.plan(
            .include(SleepPlanner.include(pending, endAt: nil, in: state)),
            receipt: nil, in: state, now: 100)
        let receipt = try #require(plan.receipt)
        let after = fixture.applying(plan.mutation, to: state)
        #expect(throws: SleepError.undoUnavailable) { try TimeReviewMutation.undo(receipt, in: after, now: 99) }
        #expect(throws: SleepError.undoUnavailable) {
            try TimeReviewMutation.undo(receipt, in: fixture.state(after.entries, pending: [pending]), now: 100)
        }
        let changed = after.entries.map {
            $0.id == receipt.entries.after[0].id
                ? fixture.row(
                    $0.startAt,
                    $0.endAt! + 1, id: $0.id) : $0
        }
        #expect(throws: SleepError.undoUnavailable) {
            try TimeReviewMutation.undo(
                receipt, in: fixture.state(changed),
                now: 100)
        }
        let reused = fixture.pending(70, 80, id: pending.id)
        #expect(throws: SleepError.undoUnavailable) {
            try TimeReviewMutation.undo(
                receipt,
                in: fixture.state(after.entries, pending: [reused]), now: 100)
        }
        let invalidOwners = TimeReviewReceipt(
            entries: CorrectionReceipt(
                before: receipt.entries.before,
                after: receipt.entries.after, originalProjectByTask: [:]), pending: pending, active: nil)
        #expect(throws: SleepError.undoUnavailable) { try TimeReviewMutation.undo(invalidOwners, in: after, now: 100) }
        let open = fixture.row(100, nil)
        let interrupted = fixture.state(
            [open],
            active: ActiveTimer(
                entryID: open.id,
                checkpointAt: 110))
        let discard = try TimeReviewMutation.plan(
            .resolveInterruption(
                SleepPlanner.interruption(
                    endAt: nil,
                    in: interrupted)),
            receipt: nil, in: interrupted, now: 110)
        let activeReceipt = try #require(discard.receipt)
        let competing = fixture.row(120, nil)
        #expect(throws: SleepError.undoUnavailable) {
            try TimeReviewMutation.undo(
                activeReceipt,
                in: fixture.state(
                    [competing],
                    active: ActiveTimer(entryID: competing.id, checkpointAt: 120)), now: 120)
        }
        #expect(throws: SleepError.undoUnavailable) {
            try TimeReviewMutation.undo(
                activeReceipt,
                in: fixture.state([fixture.row(120, 130)]), now: 130)
        }
        #expect(throws: SleepError.undoUnavailable) {
            try TimeReviewMutation.undo(
                activeReceipt,
                in: fixture.state(pending: [fixture.pending(100, nil)]), now: 130)
        }
        let unknown = fixture.pending(100, nil)
        let unknownState = fixture.state(pending: [unknown])
        let skip = try TimeReviewMutation.plan(
            .skip(SleepPlanner.skip(unknown, in: unknownState)), receipt: nil,
            in: unknownState, now: 130)
        #expect(throws: SleepError.undoUnavailable) {
            try TimeReviewMutation.undo(
                #require(skip.receipt),
                in: fixture.state(pending: [
                    fixture.pending(
                        110,
                        nil)
                ]), now: 130)
        }
        #expect(throws: SleepError.undoUnavailable) {
            try TimeReviewMutation.undo(
                #require(skip.receipt),
                in: fixture.state(
                    [competing],
                    active: ActiveTimer(entryID: competing.id, checkpointAt: 120)), now: 130)
        }
    }

    @Test func reviewDMLPersistsExactRowsAndOneRevisionUndo() async throws {
        let fixture = SleepFixture()
        let pending = fixture.pending()
        let original = fixture.row(0, 100)
        let directory = URL(
            fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path, isDirectory: true
        )
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await Library.open(at: directory)
        let seeded = try await library.transact(expectedRevision: 0) { database, _ in
            try fixture.seed(
                database,
                state: fixture.state([original], pending: [pending]))
        }
        let shown = try SleepPlanner.include(pending, endAt: nil, in: seeded.snapshot)
        let saved = try await library.performTimeReview(
            .include(shown), receipt: nil, expectedRevision: 1,
            instant: 100)
        #expect(saved.snapshot.revision == 2 && saved.snapshot.pendingSleepIntervals.isEmpty)
        #expect(saved.snapshot.entries.contains(shown.correction.adjustments[0].retained[1]))
        let undone = try await library.performTimeReview(.undo, receipt: saved.value, expectedRevision: 2, instant: 100)
        #expect(undone.snapshot.revision == 3 && undone.snapshot.entries == [original])
        #expect(undone.snapshot.pendingSleepIntervals == [pending] && undone.value == nil)
        await library.close()
        let reopened = try await Library.open(at: directory)
        #expect(try await reopened.snapshot() == undone.snapshot)
        await reopened.close()
    }

    @Test @MainActor func receiptTimeBoundaryWakeSwitchRepeatedSleepAndReopen() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        _ = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        fixture.clock.set(110)
        let generation = model.timerLifecycleGate.latchSleep()
        fixture.clock.set(900)
        await model.enqueueSleepObservation(generation: generation).value
        let sleeping = try #require(model.snapshot)
        let pending = try #require(sleeping.pendingSleepIntervals.first)
        #expect(sleeping.entries.first?.endAt == 110 && sleeping.activeTimer == nil && pending.sleepAt == 110)
        await model.enqueueWakeObservation(generation: generation, observedAt: 120).value
        let awake = try #require(model.snapshot)
        let activeID = try #require(awake.activeTimer?.entryID)
        #expect(awake.entries.first { $0.id == activeID }?.startAt == 120)
        #expect(awake.pendingSleepIntervals.first?.wakeAt == 120)
        await model.enqueueWakeObservation(generation: generation, observedAt: 125).value
        #expect(model.snapshot == awake)
        fixture.clock.set(130)
        _ = try await model.enqueueTimer(.checkpoint).value
        _ = try await model.enqueueTimer(.start(taskID: fixture.second)).value
        fixture.clock.set(140)
        let second = model.timerLifecycleGate.latchSleep()
        await model.enqueueSleepObservation(generation: second).value
        await model.enqueueWakeObservation(generation: generation, observedAt: 150).value
        #expect(model.timerLifecycleGate.state().sleeping)
        await model.enqueueWakeObservation(generation: second, observedAt: 150).value
        let again = try #require(model.snapshot)
        #expect(again.pendingSleepIntervals.count == 2)
        #expect(again.pendingSleepIntervals.first { $0.id == pending.id }?.taskID == fixture.first)
        await model.close()
        try await model.open()
        await model.enqueueWakeObservation(generation: second, observedAt: 160).value
        #expect(model.snapshot == again && model.timerStatus == .reviewRequired)
        #expect(!model.canUndoTimeReview)
        await fixture.dispose()
    }

    @Test @MainActor func idleEqualReversedAndUnknownRequireExplicitReview() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let idle = try #require(model.snapshot)
        let idleGeneration = model.timerLifecycleGate.latchSleep()
        await model.enqueueSleepObservation(generation: idleGeneration).value
        await model.enqueueWakeObservation(generation: idleGeneration, observedAt: 100).value
        #expect(model.snapshot == idle && !model.timerLifecycleGate.state().sleeping)
        _ = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        let equal = model.timerLifecycleGate.latchSleep()
        await model.enqueueSleepObservation(generation: equal).value
        #expect(model.snapshot?.entries.isEmpty == true)
        await model.enqueueWakeObservation(generation: equal, observedAt: 100).value
        #expect(model.snapshot?.pendingSleepIntervals.isEmpty == true && model.snapshot?.activeTimer != nil)
        fixture.clock.set(110)
        let reversed = model.timerLifecycleGate.latchSleep()
        await model.enqueueSleepObservation(generation: reversed).value
        let sleeping = try #require(model.snapshot)
        await model.enqueueWakeObservation(generation: reversed, observedAt: 109).value
        await model.enqueueWakeObservation(generation: reversed, observedAt: 120).value
        #expect(model.snapshot == sleeping && model.timerLifecycleGate.state().sleeping)
        await #expect(throws: TimerError.reviewRequired) {
            try await model.enqueueTimer(.start(taskID: fixture.second)).value
        }
        let shown = try SleepPlanner.skip(#require(sleeping.pendingSleepIntervals.first), in: sleeping)
        _ = try await model.enqueueTimeReview(.skip(shown)).value
        #expect(!model.timerLifecycleGate.state().sleeping && model.canUndoTimeReview)
        _ = try await model.enqueueTimeReview(.undo).value
        #expect(model.snapshot?.pendingSleepIntervals == sleeping.pendingSleepIntervals && !model.canUndoTimeReview)
        await #expect(throws: TimerError.reviewRequired) {
            try await model.enqueueTimer(.start(taskID: fixture.second)).value
        }
        await model.enqueueWakeObservation(generation: reversed, observedAt: 130).value
        #expect(model.snapshot?.activeTimer == nil)
        await fixture.dispose()
    }

    @Test @MainActor func interruptedUndoRestoresPausedUnownedWithoutContinuation() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        _ = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        fixture.clock.set(110)
        let checkpointed = try await model.enqueueTimer(.checkpoint).value
        let ownedReview = try SleepPlanner.interruption(endAt: 110, in: checkpointed)
        await #expect(throws: TimerError.reviewRequired) {
            try await model.enqueueTimeReview(.resolveInterruption(ownedReview)).value
        }
        await model.close()
        try await model.open()
        fixture.clock.set(900)
        let shown = try SleepPlanner.interruption(
            endAt: checkpointed.activeTimer?.checkpointAt,
            in: #require(model.snapshot))
        let saved = try await model.enqueueTimeReview(.resolveInterruption(shown)).value
        #expect(saved.entries.first?.endAt == 110 && saved.activeTimer == nil && model.canUndoTimeReview)
        let restored = try await model.enqueueTimeReview(.undo).value
        #expect(restored.entries == checkpointed.entries && restored.activeTimer == checkpointed.activeTimer)
        #expect(model.timerStatus == .reviewRequired && !model.canUndoTimeReview)
        #expect(try model.timerElapsedSeconds() == 10)
        await #expect(throws: TimerError.reviewRequired) {
            try await model.enqueueTimer(.start(taskID: fixture.second)).value
        }
        await fixture.dispose()
    }
}

extension SleepTests {
    @Test func transactionFaultsRestoreAllReviewAndUndoRowsOrBlockUntilReopen() async throws {
        for undoing in [false, true] {
            for interruption in [false, true] {
                for fault in [CommitFault.beforeCommit, .commitRejected, .acknowledgementLost, .rollbackFailure] {
                    let fixture = SleepFixture()
                    let row = fixture.row(0, interruption ? nil : 100)
                    let pending = fixture.pending()
                    let initial =
                        interruption
                        ? fixture.state([row], active: ActiveTimer(entryID: row.id, checkpointAt: 50))
                        : fixture.state([row], pending: [pending])
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let url = directory.appendingPathComponent("private.sqlite")
                    try Storage.createPrivateDatabase(at: url)
                    let database = try Storage(privateDatabaseAt: url)
                    let seeded = try await database.transact(expectedRevision: 0) { database, _ in
                        try fixture.seed(database, state: initial)
                    }
                    let command: TimeReviewCommand =
                        interruption
                        ? .resolveInterruption(try SleepPlanner.interruption(endAt: 50, in: seeded.snapshot))
                        : .include(try SleepPlanner.include(pending, endAt: nil, in: seeded.snapshot))
                    let plan = try TimeReviewMutation.plan(command, receipt: nil, in: seeded.snapshot, now: 100)
                    let before: LibrarySnapshot
                    if undoing {
                        before = try await database.transact(expectedRevision: 1) { database, _ in
                            try plan.mutation.apply(to: database)
                        }.snapshot
                    } else {
                        before = seeded.snapshot
                    }
                    let mutation =
                        undoing
                        ? try TimeReviewMutation.undo(#require(plan.receipt), in: before, now: 100)
                        : plan.mutation
                    await #expect(throws: StorageError.self) {
                        try await database.transact(expectedRevision: before.revision, fault: fault) { database, _ in
                            try mutation.apply(to: database)
                        }
                    }
                    if fault == .beforeCommit || fault == .commitRejected {
                        #expect(try await database.snapshot() == before)
                    } else {
                        await #expect(throws: StorageError.unavailable) { try await database.snapshot() }
                    }
                    await database.close()
                    let reopened = try Storage(privateDatabaseAt: url)
                    let saved = try await reopened.snapshot()
                    #expect(saved.revision == before.revision + (fault == .acknowledgementLost ? 1 : 0))
                    let expected = fault == .acknowledgementLost ? fixture.applying(mutation, to: before) : before
                    #expect(CorrectionPlanner.ordered(saved.entries) == CorrectionPlanner.ordered(expected.entries))
                    #expect(saved.activeTimer == expected.activeTimer)
                    #expect(saved.pendingSleepIntervals == expected.pendingSleepIntervals)
                    await reopened.close()
                }
            }
        }
    }
}
