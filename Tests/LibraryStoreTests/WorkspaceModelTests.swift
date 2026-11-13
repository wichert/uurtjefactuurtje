import Foundation
import Testing

@testable import LibraryStore

private func workspaceDirectory() -> URL {
    URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path, isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private actor WorkspaceTestGate {
    private var entered = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    func hold() async {
        entered = true
        for waiter in enterWaiters { waiter.resume() }
        enterWaiters.removeAll()
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enterWaiters.append($0) } }
    }
    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@Suite @MainActor struct WorkspaceModelTests {
    @Test func budgetCheckpointEditBatchesRearmAndReopen() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let parent = UUID()
        var value = try #require(model.snapshot)
        value = try await model.submit(
            .createTask(
                id: parent, projectID: fixture.project, parentID: nil,
                name: "Budget root", budgetMinutes: 100), expectedRevision: value.revision)
        let leaf = UUID()
        value = try await model.submit(
            .createTask(
                id: leaf, projectID: fixture.project, parentID: parent,
                name: "Budget leaf", budgetMinutes: 100), expectedRevision: value.revision)
        fixture.clock.set(1000)
        let started = try await model.enqueueTimer(.start(taskID: leaf)).value
        fixture.clock.set(999)
        #expect(try model.timerElapsedSeconds() == 0)
        #expect(try model.budgetUsage()[parent] == 0)
        #expect(model.snapshot == started)
        fixture.clock.set(5800)
        let reads = fixture.clock.reads
        #expect(try model.timerElapsedSeconds() == 4800)
        #expect(try model.budgetUsage()[parent] == 4800)
        #expect(model.snapshot == started)
        #expect(model.budgetWarnings.isEmpty)
        #expect(fixture.clock.reads == reads + 2)
        let saved = try await model.submit(
            .editTask(id: leaf, name: "Saved", budgetMinutes: 80),
            expectedRevision: started.revision)
        #expect(saved.revision == started.revision + 1)
        #expect(saved.activeTimer?.checkpointAt == 5800)
        #expect(saved.tasks.first { $0.id == leaf }?.name == "Saved")
        let batch = try #require(model.budgetWarnings.first)
        #expect(batch.warnings.map(\.taskID) == [parent, leaf].sorted { $0.uuidString < $1.uuidString })
        #expect(batch.warnings.first { $0.taskID == parent }?.threshold == .eighty)
        #expect(batch.warnings.first { $0.taskID == leaf }?.threshold == .hundred)
        _ = try await model.enqueueTimer(.checkpoint).value
        #expect(model.budgetWarnings.count == 1)
        model.dismissBudgetWarning(batch.id)
        let renamed = try await model.submit(
            .renameTask(id: leaf, name: "Rename only"), expectedRevision: saved.revision)
        #expect(renamed.tasks.first { $0.id == leaf }?.budgetMinutes == 80)
        let reset = try await model.submit(
            .editTask(id: leaf, name: "Unset", budgetMinutes: nil), expectedRevision: renamed.revision)
        #expect(model.budgetWarnings.isEmpty)
        let enabled = try await model.submit(
            .editTask(id: leaf, name: "Enabled", budgetMinutes: 50), expectedRevision: reset.revision)
        #expect(model.budgetWarnings.count == 1)
        #expect(model.budgetWarnings[0].warnings == [BudgetWarning(taskID: leaf, threshold: .hundred)])
        fixture.clock.set(5860)
        do {
            _ = try await model.submit(
                .editTask(id: leaf, name: "Too large", budgetMinutes: 101), expectedRevision: enabled.revision)
            Issue.record("allocation unexpectedly succeeded")
        } catch CommandError.budgetAllocation(let id, let allowance) {
            #expect(id == leaf)
            #expect(allowance.limitingAncestorID == parent)
            #expect(allowance.maximumMinutes == 100)
        }
        #expect(model.snapshot == enabled)
        #expect(model.timerStatus == .paused(entryID: enabled.activeTimer!.entryID))
        let pausedReads = fixture.clock.reads
        #expect(try model.timerElapsedSeconds() == 4800)
        #expect(try model.budgetUsage()[parent] == 4800)
        #expect(fixture.clock.reads == pausedReads)
        await model.close()
        try await model.open()
        #expect(model.budgetWarnings.isEmpty)
        #expect(try model.timerElapsedSeconds() == 4800)
        #expect(try model.budgetUsage()[leaf] == 4800)
        #expect(fixture.clock.reads == pausedReads)
        await fixture.dispose()
    }

    @Test func budgetFormsShareFIFOAndSleepLatchPreventsSampling() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        fixture.clock.set(1000)
        let started = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        let generation = model.timerLifecycleGate.latchSleep()
        let reads = fixture.clock.reads
        #expect(try model.timerElapsedSeconds() == 0)
        #expect(try model.budgetUsage()[fixture.first] == 0)
        let first = model.enqueueSubmit(
            .editTask(id: fixture.first, name: "One", budgetMinutes: 1), expectedRevision: started.revision)
        let stale = model.enqueueSubmit(
            .editTask(id: fixture.first, name: "Stale", budgetMinutes: 2), expectedRevision: started.revision)
        let saved = try await first.value
        do {
            _ = try await stale.value
            Issue.record("stale form succeeded")
        } catch StorageError.revisionConflict {}
        #expect(model.snapshot == saved)
        #expect(saved.activeTimer == started.activeTimer)
        #expect(model.budgetWarnings.isEmpty)
        #expect(fixture.clock.reads == reads)
        await model.enqueueSleepObservation(generation: generation).value
        #expect(model.timerStatus == .reviewRequired && model.snapshot?.activeTimer == nil)
        #expect(model.snapshot?.pendingSleepIntervals.first?.sleepAt == 1000)
        await fixture.dispose()
    }

    @Test func concurrentSleepLatchBehindFIFOLeavesCheckpointUnchanged() async throws {
        let directory = workspaceDirectory()
        let clock = TimerTestClock(1000)
        let barrier = TimerTestBarrier()
        var operations = WorkspaceOperations()
        operations.performOwned = { library, command, revision, owned in
            await barrier.hold()
            return try await library.performOwned(command, expectedRevision: revision, ownedTimerEntryID: owned)
        }
        let model = WorkspaceModel(directory: directory, operations: operations)
        model.configureTimer(clock: { clock.read() })
        try await model.open()
        let project = UUID()
        let leaf = UUID()
        _ = try await model.submit(
            .createProject(id: project, name: "Client", rate: 1, currency: "EUR"), expectedRevision: 0)
        _ = try await model.submit(
            .createTask(id: leaf, projectID: project, parentID: nil, name: "Leaf", budgetMinutes: 1),
            expectedRevision: 1)
        let started = try await model.enqueueTimer(.start(taskID: leaf)).value
        let rename = model.enqueueSubmit(.renameTask(id: leaf, name: "First"), expectedRevision: started.revision)
        await barrier.wait()
        let edit = model.enqueueSubmit(
            .editTask(id: leaf, name: "Second", budgetMinutes: 2), expectedRevision: started.revision + 1)
        let reads = clock.reads
        let gate = model.timerLifecycleGate
        let generation = await Task.detached { gate.latchSleep() }.value
        clock.set(9000)
        await barrier.release()
        _ = try await rename.value
        let saved = try await edit.value
        #expect(saved.activeTimer == started.activeTimer)
        #expect(clock.reads == reads + 1)  // latchSleep itself captures one receipt-time boundary.
        #expect(model.budgetWarnings.isEmpty)
        #expect(try model.timerElapsedSeconds() == 0)
        await model.enqueueSleepObservation(generation: generation).value
        await model.close()
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func failedSampledBudgetPublicationPausesWithoutBatchesOrPartialState() async throws {
        for mode in 0..<3 {
            let directory = workspaceDirectory()
            let clock = TimerTestClock(1000)
            var operations = WorkspaceOperations()
            operations.performBudget = { library, command, revision, owned, instant in
                if mode == 0 { throw StorageError.injectedFailure }
                if mode == 1 { throw StorageError.sqlite(5, "rejected") }
                _ = try await library.performOwned(
                    command, expectedRevision: revision,
                    ownedTimerEntryID: owned, checkpointAt: instant)
                throw LibraryAccessError.publicationIndeterminate
            }
            let model = WorkspaceModel(directory: directory, operations: operations)
            model.configureTimer(clock: { clock.read() })
            try await model.open()
            let project = UUID()
            let leaf = UUID()
            _ = try await model.submit(
                .createProject(id: project, name: "Client", rate: 1, currency: "EUR"), expectedRevision: 0)
            _ = try await model.submit(
                .createTask(id: leaf, projectID: project, parentID: nil, name: "Leaf"), expectedRevision: 1)
            let before = try await model.enqueueTimer(.start(taskID: leaf)).value
            clock.set(7000)
            do {
                _ = try await model.submit(
                    .editTask(id: leaf, name: "Crossed", budgetMinutes: 50), expectedRevision: before.revision)
                Issue.record("fault returned success")
            } catch {}
            #expect(model.snapshot == before)
            #expect(model.budgetWarnings.isEmpty)
            #expect(model.timerStatus == .paused(entryID: before.activeTimer!.entryID))
            let reads = clock.reads
            #expect(try model.timerElapsedSeconds() == 0)
            #expect(try model.budgetUsage()[leaf] == 0)
            #expect(clock.reads == reads)
            if mode == 2 { #expect(model.availability == .blocked) }
            await model.close()
            try await model.open()
            #expect(model.budgetWarnings.isEmpty)
            #expect(model.snapshot?.revision == before.revision + (mode == 2 ? 1 : 0))
            await model.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func sharedFIFOConflictCancellationAndCloseBarrier() async throws {
        let directory = workspaceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = WorkspaceTestGate()
        var operations = WorkspaceOperations()
        operations.perform = { library, command, revision in
            await gate.hold()
            return try await library.perform(command, expectedRevision: revision)
        }
        let model = WorkspaceModel(directory: directory, operations: operations)
        let firstConsumer = model
        let secondConsumer = model
        try await model.open()
        let project = UUID()
        let draft = "Stale draft"
        let first = firstConsumer.enqueueSubmit(
            .createProject(id: project, name: "Client", rate: 1, currency: "EUR"), expectedRevision: 0)
        await gate.waitUntilEntered()
        let stale = secondConsumer.enqueueSubmit(
            .createProject(id: UUID(), name: draft, rate: 0, currency: "EUR"), expectedRevision: 0)
        stale.cancel()
        #expect(model.isBusy)
        await gate.release()
        let committed = try await first.value
        await #expect(throws: StorageError.revisionConflict(expected: 0, actual: 1)) { try await stale.value }
        #expect(firstConsumer.snapshot == committed && secondConsumer.snapshot == committed)
        #expect(model.issue == .revisionConflict && draft == "Stale draft")
        #expect(!model.isBusy)

        let beforeClose = model.enqueueSubmit(
            .renameTask(id: UUID(), name: "Missing"), expectedRevision: committed.revision)
        let close = model.enqueueClose()
        let rejected = model.enqueueSubmit(
            .setArchived(id: project, archived: true),
            expectedRevision: committed.revision)
        await #expect(throws: CommandError.missingRecord) { try await beforeClose.value }
        await #expect(throws: LibraryAccessError.unavailable) { try await rejected.value }
        await close.value
        #expect(model.availability == .closed && model.snapshot == nil && !model.isBusy)
        try await model.open()
        #expect(model.snapshot == committed)
        await model.close()
    }

    @Test func failedSnapshotReleasesLeaseAndRetryIsExplicit() async throws {
        let directory = workspaceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = SnapshotFault()
        var operations = WorkspaceOperations()
        operations.snapshot = { library in
            if await calls.first() { throw StorageError.invalidStorage("injected read") }
            return try await library.snapshot()
        }
        let model = WorkspaceModel(directory: directory, operations: operations)
        await #expect(throws: StorageError.invalidStorage("injected read")) { try await model.open() }
        #expect(model.availability == .blocked && model.issue == .invalidStorage)
        let independent = try await Library.open(at: directory)
        await independent.close()
        try await model.open()
        #expect(model.availability == .ready && model.snapshot?.revision == 0)
        await model.close()
    }

    @Test func uncertainPublicationBlocksUntilReopenWithoutReplay() async throws {
        let directory = workspaceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = SnapshotFault()
        var operations = WorkspaceOperations()
        operations.perform = { library, command, revision in
            if await calls.first() {
                _ = try await library.perform(command, expectedRevision: revision)
                throw LibraryAccessError.publicationIndeterminate
            }
            return try await library.perform(command, expectedRevision: revision)
        }
        let model = WorkspaceModel(directory: directory, operations: operations)
        try await model.open()
        let original = model.snapshot
        let id = UUID()
        await #expect(throws: LibraryAccessError.publicationIndeterminate) {
            try await model.submit(
                .createProject(id: id, name: "Client", rate: 0, currency: "EUR"), expectedRevision: 0)
        }
        #expect(model.availability == .blocked && model.issue == .uncertainSave && model.snapshot == original)
        await #expect(throws: LibraryAccessError.unavailable) {
            try await model.submit(.setArchived(id: id, archived: true), expectedRevision: 0)
        }
        try await model.open()
        #expect(model.snapshot?.revision == 1 && model.snapshot?.projects.first?.id == id)
        #expect(model.snapshot?.projects.first?.isArchived == false)
        await model.close()
    }

    @Test func reviewRequiredAndTypedFailures() async throws {
        let directory = workspaceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try await Library.open(at: directory)
        let project = UUID()
        let task = UUID()
        var snapshot = try await owner.perform(
            .createProject(id: project, name: "Client", rate: 0, currency: "EUR"), expectedRevision: 0)
        snapshot = try await owner.perform(
            .createTask(id: task, projectID: project, parentID: nil, name: "Work"), expectedRevision: snapshot.revision)
        _ = try await owner.transact(expectedRevision: snapshot.revision) { database, _ in
            try database.runCommand(
                "INSERT INTO pending_sleep_intervals(id,task_id,sleep_at,wake_at) VALUES (?,?,?,?)",
                bindings: [
                    .text(UUID().uuidString.lowercased()), .text(task.uuidString.lowercased()), .integer(1), .integer(2)
                ], expectedChanges: 1)
        }
        let model = WorkspaceModel(directory: directory)
        await #expect(throws: LibraryOpenError.busy) { try await model.open() }
        #expect(model.issue == .busy && model.availability == .blocked)
        await owner.close()
        try await model.open()
        #expect(model.availability == .ready && model.snapshot?.pendingSleepIntervals.count == 1)
        let before = model.snapshot
        await #expect(throws: CommandError.recoveryRequired) {
            try await model.submit(.renameTask(id: task, name: "No"), expectedRevision: before!.revision)
        }
        #expect(model.issue == .recoveryRequired && model.snapshot == before)
        await model.close()
    }
}

private actor SnapshotFault {
    private var pending = true
    func first() -> Bool {
        defer { pending = false }
        return pending
    }
}

extension WorkspaceModelTests {
    @Test func migrationUndoSharesFIFOAndTimerOwnership() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let started = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        let request = TaskCreationRequest(
            id: UUID(), projectID: fixture.project, parentID: fixture.first,
            name: "Child", confirmMigration: true, start: false)
        let creation = model.enqueueTaskCreation(request, expectedRevision: started.revision)
        guard case .unavailable = model.migrationUndoAvailability else {
            Issue.record("Undo enabled while mutating")
            return
        }
        let result = try await creation.value
        #expect(result.snapshot.activeTimer == started.activeTimer)
        guard case .available(let receipt) = model.migrationUndoAvailability else {
            Issue.record("Undo not available")
            return
        }
        let undone = try await model.enqueueMigrationUndo(receiptID: receipt).value
        #expect(undone.entries.first?.taskID == fixture.first && undone.activeTimer == started.activeTimer)
        #expect(model.timerStatus == .running(entryID: started.activeTimer!.entryID))
        await fixture.dispose()
    }

    @Test func creationAcceptedBeforeCloseAndNewSleepGenerationStaysLatched() async throws {
        let directory = workspaceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let barrier = WorkspaceTestGate()
        var operations = WorkspaceOperations()
        operations.createTask = { library, request, revision, owned, instant in
            await barrier.hold()
            return try await library.createTaskOwned(
                request, expectedRevision: revision, ownedTimerEntryID: owned,
                instant: instant)
        }
        let model = WorkspaceModel(directory: directory, operations: operations)
        model.configureTimer(clock: { 100 })
        try await model.open()
        let project = UUID()
        let parent = UUID()
        let created = try await model.submit(
            .createProject(id: project, name: "Client", rate: 0, currency: "EUR"), expectedRevision: 0)
        let before = try await model.submit(
            .createTask(id: parent, projectID: project, parentID: nil, name: "Parent"),
            expectedRevision: created.revision)
        let request = TaskCreationRequest(
            id: UUID(), projectID: project, parentID: parent, name: "Child", confirmMigration: true, start: true)
        let work = model.enqueueTaskCreation(request, expectedRevision: before.revision)
        await barrier.waitUntilEntered()
        work.cancel()
        let generation = model.timerLifecycleGate.latchSleep()
        let close = model.enqueueClose()
        await #expect(throws: LibraryAccessError.unavailable) {
            try await model.enqueueTaskCreation(request, expectedRevision: before.revision).value
        }
        await barrier.release()
        let result = try await work.value
        #expect(result.snapshot.activeTimer != nil)
        #expect(model.timerLifecycleGate.state().generation == generation && model.timerLifecycleGate.state().sleeping)
        await close.value
        try await model.open()
        #expect(model.snapshot == result.snapshot && model.timerStatus == .reviewRequired)
        await model.close()
    }

    @Test func creationPublicationFailureBlocksAndDoesNotReplay() async throws {
        let directory = workspaceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var operations = WorkspaceOperations()
        operations.createTask = { library, request, revision, owned, instant in
            _ = try await library.createTaskOwned(
                request, expectedRevision: revision, ownedTimerEntryID: owned,
                instant: instant)
            throw LibraryAccessError.publicationIndeterminate
        }
        let model = WorkspaceModel(directory: directory, operations: operations)
        try await model.open()
        let project = UUID()
        let parent = UUID()
        let created = try await model.submit(
            .createProject(id: project, name: "Client", rate: 0, currency: "EUR"), expectedRevision: 0)
        let before = try await model.submit(
            .createTask(id: parent, projectID: project, parentID: nil, name: "Parent"),
            expectedRevision: created.revision)
        let request = TaskCreationRequest(
            id: UUID(), projectID: project, parentID: parent, name: "Child", confirmMigration: true, start: false)
        await #expect(throws: LibraryAccessError.publicationIndeterminate) {
            try await model.enqueueTaskCreation(request, expectedRevision: before.revision).value
        }
        #expect(model.snapshot == before && model.availability == .blocked && model.issue == .uncertainSave)
        guard case .unavailable = model.migrationUndoAvailability else {
            Issue.record("Blocked workspace enabled undo")
            return
        }
        try await model.open()
        #expect(model.snapshot?.tasks.filter { $0.id == request.id }.count == 1)
        guard case .unavailable = model.migrationUndoAvailability else {
            Issue.record("Reopen retained receipt")
            return
        }
        await model.close()
    }

    @Test func pausedMigrationPreservesSleepLatch() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let started = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        let generation = model.timerLifecycleGate.latchSleep()
        let request = TaskCreationRequest(
            id: UUID(), projectID: fixture.project, parentID: fixture.first,
            name: "Child", confirmMigration: true, start: false)
        let result = try await model.enqueueTaskCreation(request, expectedRevision: started.revision).value
        #expect(result.snapshot.activeTimer == started.activeTimer)
        #expect(model.timerLifecycleGate.state().sleeping)
        #expect(model.timerStatus == .paused(entryID: started.activeTimer!.entryID))
        guard case .available(let receipt) = model.migrationUndoAvailability else {
            Issue.record("Paused migration not undoable")
            return
        }
        _ = try await model.enqueueMigrationUndo(receiptID: receipt).value
        #expect(model.timerStatus == .paused(entryID: started.activeTimer!.entryID))
        await model.enqueueSleepObservation(generation: generation).value
        #expect(model.timerStatus == .reviewRequired && model.snapshot?.activeTimer == nil)
        await fixture.dispose()
    }

    @Test func migrationCheckpointInvalidatesUndoAndCloseClearsIt() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let started = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        let request = TaskCreationRequest(
            id: UUID(), projectID: fixture.project, parentID: fixture.first,
            name: "Child", confirmMigration: true, start: false)
        _ = try await model.enqueueTaskCreation(request, expectedRevision: started.revision).value
        guard case .available(let receipt) = model.migrationUndoAvailability else {
            Issue.record("Undo not available")
            return
        }
        fixture.clock.set(110)
        let checkpoint = model.enqueueTimer(.checkpoint)
        guard case .unavailable = model.migrationUndoAvailability else {
            Issue.record("Undo enabled during checkpoint")
            return
        }
        _ = try await checkpoint.value
        guard case .unavailable = model.migrationUndoAvailability else {
            Issue.record("Checkpoint did not invalidate undo")
            return
        }
        await #expect(throws: CommandError.undoUnavailable) {
            try await model.enqueueMigrationUndo(receiptID: receipt).value
        }
        await model.close()
        try await model.open()
        guard case .unavailable = model.migrationUndoAvailability else {
            Issue.record("Reopen retained undo")
            return
        }
        await fixture.dispose()
    }

    @Test func createAndStartUsesOneSampleAndOneRevision() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let started = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        fixture.clock.set(110)
        let beforeReads = fixture.clock.reads
        let request = TaskCreationRequest(
            id: UUID(), projectID: fixture.project, parentID: fixture.first,
            name: "Child", confirmMigration: true, start: true)
        let result = try await model.enqueueTaskCreation(request, expectedRevision: started.revision).value
        #expect(result.snapshot.revision == started.revision + 1 && fixture.clock.reads == beforeReads + 1)
        #expect(result.snapshot.entries.contains { $0.taskID == request.id && $0.startAt == 110 && $0.endAt == nil })
        guard case .unavailable = model.migrationUndoAvailability else {
            Issue.record("Started task allowed undo")
            return
        }
        await fixture.dispose()
    }
    @Test func timerFIFOCoalescingCheckpointLimitAndClose() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let barrier = TimerTestBarrier()
        model.configureTimer(
            clock: { fixture.clock.read() },
            write: { library, command, revision, instant, id in
                await barrier.hold()
                return try await library.performTimer(
                    command, expectedRevision: revision, instant: instant, newEntryID: id)
            })
        let start = model.enqueueTimer(.start(taskID: fixture.first))
        await barrier.wait()
        let duplicate = model.enqueueTimer(.start(taskID: fixture.first))
        duplicate.cancel()
        let checkpoint = model.enqueueTimer(.checkpoint)
        let switched = model.enqueueTimer(.start(taskID: fixture.second))
        let droppedTick = model.enqueueTimer(.checkpoint)
        let close = model.enqueueClose()
        await #expect(throws: LibraryAccessError.unavailable) { try await model.enqueueTimer(.checkpoint).value }
        await barrier.release()
        let first = try await start.value
        #expect(try await duplicate.value == first)
        #expect(try await checkpoint.value == first)
        #expect(try await droppedTick.value == first)
        let last = try await switched.value
        #expect(last.revision == first.revision + 1 && last.entries.count == 1)
        await close.value
        #expect(model.snapshot == nil && !model.isBusy)
        try await model.open()
        #expect(model.snapshot == last && model.timerStatus == .reviewRequired)
        await fixture.dispose()
    }

    @Test func liveEditsPreserveTimerAndNonTimerIntentsBreakCoalescing() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let started = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        let barrier = TimerTestBarrier()
        model.configureTimer(
            clock: { fixture.clock.read() },
            write: { library, command, revision, instant, id in
                await barrier.hold()
                return try await library.performTimer(
                    command, expectedRevision: revision, instant: instant, newEntryID: id)
            })
        fixture.clock.set(110)
        let switchTask = model.enqueueTimer(.start(taskID: fixture.second))
        await barrier.wait()
        let rename = model.enqueueSubmit(
            .renameTask(id: fixture.first, name: "Renamed"), expectedRevision: started.revision + 1)
        let afterEdit = model.enqueueTimer(.start(taskID: fixture.second))
        await barrier.release()
        let switched = try await switchTask.value
        let edited = try await rename.value
        let repeated = try await afterEdit.value
        #expect(edited.activeTimer == switched.activeTimer)
        #expect(repeated == edited && repeated.revision == switched.revision + 1)
        #expect(model.availability == .ready)
        let projectEdit = try await model.submit(
            .updateProject(
                id: fixture.project, name: "Client", rate: 42, currency: "EUR", confirmedPreviousCurrency: nil),
            expectedRevision: edited.revision)
        #expect(projectEdit.activeTimer == switched.activeTimer)
        await #expect(throws: CommandError.recoveryRequired) {
            try await model.submit(
                .setArchived(id: fixture.project, archived: true),
                expectedRevision: projectEdit.revision)
        }
        await #expect(throws: CommandError.migrationRequired) {
            try await model.submit(
                .createTask(id: UUID(), projectID: fixture.project, parentID: fixture.second, name: "Child"),
                expectedRevision: projectEdit.revision)
        }
        #expect(model.snapshot == projectEdit)
        await fixture.dispose()
    }

    @Test func synchronousLatchBeforeDelayedObservationUsesReceiptBoundary() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let barrier = TimerTestBarrier()
        model.configureTimer(
            clock: { fixture.clock.read() },
            write: { library, command, revision, instant, id in
                await barrier.hold()
                return try await library.performTimer(
                    command, expectedRevision: revision, instant: instant, newEntryID: id)
            })
        let start = model.enqueueTimer(.start(taskID: fixture.first))
        await barrier.wait()  // already sampled, not yet published
        let queued = model.enqueueTimer(.start(taskID: fixture.second))
        let generation = model.timerLifecycleGate.latchSleep()
        let reads = fixture.clock.reads
        await barrier.release()
        let saved = try await start.value
        await #expect(throws: TimerError.reviewRequired) { try await queued.value }
        #expect(fixture.clock.reads == reads)
        let id = try #require(saved.activeTimer?.entryID)
        #expect(model.timerStatus == .paused(entryID: id))
        fixture.clock.set(200)
        await model.enqueueSleepObservation(generation: generation).value
        #expect(model.snapshot?.activeTimer == nil && model.snapshot?.entries.isEmpty == true)
        #expect(model.snapshot?.pendingSleepIntervals.first?.sleepAt == 100)
        await #expect(throws: TimerError.reviewRequired) { try await model.enqueueTimer(.checkpoint).value }
        await model.enqueueWakeObservation(generation: generation, observedAt: 110).value
        #expect(model.snapshot?.activeTimer?.checkpointAt == 110)
        #expect(!model.timerLifecycleGate.state().sleeping)
        await fixture.dispose()
    }

    @Test func olderWakePublicationCannotReleaseNewSleepGeneration() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        _ = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        fixture.clock.set(110)
        let first = model.timerLifecycleGate.latchSleep()
        await model.enqueueSleepObservation(generation: first).value
        let sleeping = try #require(model.snapshot)
        let barrier = TimerTestBarrier()
        model.configureSleepObservations { library, command, revision in
            let result = try await library.performSleepObservation(command, expectedRevision: revision)
            await barrier.hold()
            return result
        }
        let wake = model.enqueueWakeObservation(generation: first, observedAt: 120)
        await barrier.wait()
        #expect(model.snapshot == sleeping)
        fixture.clock.set(130)
        let second = model.timerLifecycleGate.latchSleep()
        await barrier.release()
        await wake.value
        #expect(model.snapshot?.activeTimer?.checkpointAt == 120)
        #expect(model.timerLifecycleGate.state().generation == second && model.timerLifecycleGate.state().sleeping)
        await model.enqueueSleepObservation(generation: first).value
        await #expect(throws: TimerError.reviewRequired) {
            try await model.enqueueTimer(.start(taskID: fixture.second)).value
        }
        await fixture.dispose()
    }

    @Test func failedCheckpointClearsPeriodicMarkerButKeepsPause() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        _ = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        fixture.clock.set(110)
        model.configureTimer(
            clock: { fixture.clock.read() },
            write: { _, _, _, _, _ in throw StorageError.injectedFailure })
        await #expect(throws: StorageError.injectedFailure) { try await model.enqueueTimer(.checkpoint).value }
        // A second tick must execute the pause guard, not reuse the failed task.
        await #expect(throws: TimerError.reviewRequired) { try await model.enqueueTimer(.checkpoint).value }
        #expect(!model.isBusy)
        await fixture.dispose()
    }
}

extension WorkspaceModelTests {
    @Test func correctionTimerEditFIFOAndAcceptedCancellation() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let before = try #require(model.snapshot)
        let shown = try CorrectionPlanner.preview(
            .add(id: UUID(), taskID: fixture.first, startAt: 10, endAt: 20),
            in: before)
        let correction = model.enqueueCorrection(.apply(shown))
        correction.cancel()
        let start = model.enqueueTimer(.start(taskID: fixture.second))
        let changed = try await correction.value
        let running = try await start.value
        #expect(changed.revision == before.revision + 1 && running.revision == changed.revision + 1)
        #expect(running.entries.contains(shown.draft.entry) && running.activeTimer != nil)
        let renamed = try await model.submit(
            .renameTask(id: fixture.first, name: "Renamed"), expectedRevision: running.revision)
        #expect(renamed.entries == running.entries)
        #expect(model.canUndoCorrection)
        let undone = try await model.enqueueCorrection(.undo).value
        #expect(undone.activeTimer == running.activeTimer && !undone.entries.contains(shown.draft.entry))
        #expect(!model.canUndoCorrection)
        await fixture.dispose()
    }

    @Test func queuedRenameMakesPreviewStaleWithoutBlanketRevisionCheck() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let before = try #require(model.snapshot)
        let shown = try CorrectionPlanner.preview(
            .add(id: UUID(), taskID: fixture.first, startAt: 10, endAt: 20),
            in: before)
        let rename = model.enqueueSubmit(
            .renameTask(id: fixture.first, name: "Changed"), expectedRevision: before.revision)
        let correction = model.enqueueCorrection(.apply(shown))
        _ = try await rename.value
        await #expect(throws: CorrectionError.stalePreview) { try await correction.value }
        #expect(model.snapshot?.entries.isEmpty == true && !model.canUndoCorrection)
        let fresh = try CorrectionPlanner.preview(shown.draft, in: #require(model.snapshot))
        _ = try await model.enqueueCorrection(.apply(fresh)).value
        #expect(model.canUndoCorrection)
        await fixture.dispose()
    }

    @Test func confirmedReceiptRollbackRetentionAndExplicitReopen() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let before = try #require(model.snapshot)
        let shown = try CorrectionPlanner.preview(
            .add(id: UUID(), taskID: fixture.first, startAt: 10, endAt: 20),
            in: before)
        let barrier = TimerTestBarrier()
        model.configureCorrections { library, command, receipt, revision, instant in
            let committed = try await library.performCorrection(
                command, receipt: receipt, expectedRevision: revision,
                instant: instant)
            await barrier.hold()
            return committed
        }
        let task = model.enqueueCorrection(.apply(shown))
        await barrier.wait()
        #expect(model.snapshot == before && !model.canUndoCorrection)
        await barrier.release()
        let saved = try await task.value
        #expect(saved.revision == before.revision + 1 && model.canUndoCorrection)
        model.configureCorrections { _, _, _, _, _ in throw StorageError.injectedFailure }
        await #expect(throws: StorageError.injectedFailure) { try await model.enqueueCorrection(.undo).value }
        #expect(model.snapshot == saved && model.canUndoCorrection)
        model.configureCorrections { library, command, receipt, revision, instant in
            try await library.performCorrection(command, receipt: receipt, expectedRevision: revision, instant: instant)
        }
        let undone = try await model.enqueueCorrection(.undo).value
        #expect(undone.revision == saved.revision + 1 && !model.canUndoCorrection)
        let again = try CorrectionPlanner.preview(shown.draft, in: undone)
        _ = try await model.enqueueCorrection(.apply(again)).value
        await model.close()
        try await model.open()
        #expect(!model.canUndoCorrection && model.snapshot?.entries == saved.entries)
        await fixture.dispose()
    }

    @Test func uncertainPublicationBlocksWithoutReceiptOrReplay() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let before = try #require(model.snapshot)
        let shown = try CorrectionPlanner.preview(
            .add(id: UUID(), taskID: fixture.first, startAt: 10, endAt: 20),
            in: before)
        model.configureCorrections { library, command, receipt, revision, instant in
            _ = try await library.performCorrection(
                command, receipt: receipt, expectedRevision: revision,
                instant: instant)
            throw LibraryAccessError.publicationIndeterminate
        }
        await #expect(throws: LibraryAccessError.publicationIndeterminate) {
            try await model.enqueueCorrection(.apply(shown)).value
        }
        #expect(model.availability == .blocked && model.snapshot == before && !model.canUndoCorrection)
        await #expect(throws: LibraryAccessError.unavailable) { try await model.enqueueCorrection(.apply(shown)).value }
        try await model.open()
        #expect(model.snapshot?.revision == before.revision + 1 && model.snapshot?.entries == [shown.draft.entry])
        #expect(!model.canUndoCorrection)
        await fixture.dispose()
    }

    @Test func queuedGenerationMismatchAndLaterLatchArePreserved() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let before = try #require(model.snapshot)
        let one = try CorrectionPlanner.preview(
            .add(id: UUID(), taskID: fixture.first, startAt: 10, endAt: 20),
            in: before)
        let two = try CorrectionPlanner.preview(
            .add(id: UUID(), taskID: fixture.second, startAt: 30, endAt: 40),
            in: before)
        let barrier = TimerTestBarrier()
        model.configureCorrections { library, command, receipt, revision, instant in
            let committed = try await library.performCorrection(
                command, receipt: receipt, expectedRevision: revision,
                instant: instant)
            await barrier.hold()
            return committed
        }
        let first = model.enqueueCorrection(.apply(one))
        await barrier.wait()
        let second = model.enqueueCorrection(.apply(two))
        let generation = model.timerLifecycleGate.latchSleep()
        await barrier.release()
        _ = try await first.value
        await #expect(throws: TimerError.reviewRequired) { try await second.value }
        #expect(model.timerLifecycleGate.state().generation == generation)
        #expect(model.timerLifecycleGate.state().sleeping && !model.canUndoCorrection)
        #expect(model.snapshot?.entries == [one.draft.entry])
        await fixture.dispose()
    }

    @Test func correctionRejectsRestoredPausedAndPendingReview() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let running = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        let shown = try CorrectionPlanner.preview(
            .add(id: UUID(), taskID: fixture.second, startAt: 10, endAt: 20),
            in: running)
        fixture.clock.set(99)
        await #expect(throws: TimerError.clockRollback) { try await model.enqueueCorrection(.apply(shown)).value }
        fixture.clock.set(110)
        await #expect(throws: TimerError.reviewRequired) { try await model.enqueueCorrection(.apply(shown)).value }
        await model.close()
        try await model.open()
        await #expect(throws: TimerError.reviewRequired) { try await model.enqueueCorrection(.apply(shown)).value }
        #expect(model.snapshot == running && !model.canUndoCorrection)
        await fixture.dispose()
        let gate = TimerLifecycleGate()
        let correctionFixture = CorrectionFixture()
        for wake: Int64? in [nil, 60] {
            let pending = PendingSleepInterval(id: UUID(), taskID: correctionFixture.leaf, sleepAt: 50, wakeAt: wake)
            #expect(throws: TimerError.reviewRequired) {
                try gate.correctionSample(
                    in: correctionFixture.state(pending: [pending]), ownedEntryID: nil, paused: false,
                    clock: { 100 })
            }
        }
    }
}

extension WorkspaceModelTests {
    @Test func reviewFIFOAcceptedCancellationAndReceiptPublication() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        _ = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        fixture.clock.set(110)
        let generation = model.timerLifecycleGate.latchSleep()
        await model.enqueueSleepObservation(generation: generation).value
        let before = try #require(model.snapshot)
        let shown = try SleepPlanner.skip(#require(before.pendingSleepIntervals.first), in: before)
        let barrier = TimerTestBarrier()
        model.configureTimeReview { library, command, receipt, revision, instant in
            let committed = try await library.performTimeReview(
                command, receipt: receipt, expectedRevision: revision,
                instant: instant)
            await barrier.hold()
            return committed
        }
        let task = model.enqueueTimeReview(.skip(shown))
        task.cancel()
        await barrier.wait()
        #expect(model.snapshot == before && !model.canUndoTimeReview)
        let start = model.enqueueTimer(.start(taskID: fixture.second))
        await barrier.release()
        let saved = try await task.value
        let started = try await start.value
        #expect(saved.revision == before.revision + 1 && started.revision == saved.revision + 1)
        #expect(!model.canUndoTimeReview && !model.canUndoCorrection)
        // An unknown-pending Undo cannot coexist with the newly owned active row.
        await #expect(throws: SleepError.undoUnavailable) { try await model.enqueueTimeReview(.undo).value }
        #expect(model.snapshot == started)
        let stop = try await model.enqueueTimer(.stop(expectedEntryID: started.activeTimer?.entryID)).value
        #expect(model.canUndoTimeReview && stop.activeTimer == nil)
        _ = try await model.enqueueTimeReview(.undo).value
        #expect(!model.canUndoTimeReview && model.snapshot?.pendingSleepIntervals == before.pendingSleepIntervals)
        await fixture.dispose()
    }

    @Test func acceptedReviewCannotCrossGenerationAndOldPublicationDoesNotResetNewLatch() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        _ = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        fixture.clock.set(110)
        let first = model.timerLifecycleGate.latchSleep()
        await model.enqueueSleepObservation(generation: first).value
        let sleeping = try #require(model.snapshot)
        let shown = try SleepPlanner.skip(#require(sleeping.pendingSleepIntervals.first), in: sleeping)
        let barrier = TimerTestBarrier()
        model.configureTimeReview { library, command, receipt, revision, instant in
            let committed = try await library.performTimeReview(
                command, receipt: receipt, expectedRevision: revision,
                instant: instant)
            await barrier.hold()
            return committed
        }
        let accepted = model.enqueueTimeReview(.skip(shown))
        await barrier.wait()
        let queued = model.enqueueTimeReview(.skip(shown))
        let second = model.timerLifecycleGate.latchSleep()
        await barrier.release()
        let saved = try await accepted.value
        await #expect(throws: TimerError.reviewRequired) { try await queued.value }
        #expect(model.snapshot == saved && model.timerLifecycleGate.state().generation == second)
        #expect(model.timerLifecycleGate.state().sleeping)
        await model.enqueueWakeObservation(generation: first, observedAt: 120).value
        #expect(model.snapshot == saved && model.timerLifecycleGate.state().sleeping)
        await fixture.dispose()
    }

    @Test func sleepWakeFailuresNeverPublishPartialStateOrInventContinuation() async throws {
        for waking in [false, true] {
            for mode in 0..<3 {
                let fixture = try await TimerFixture.make()
                let model = fixture.model
                _ = try await model.enqueueTimer(.start(taskID: fixture.first)).value
                fixture.clock.set(110)
                let generation = model.timerLifecycleGate.latchSleep()
                if waking { await model.enqueueSleepObservation(generation: generation).value }
                let before = try #require(model.snapshot)
                model.configureSleepObservations { library, command, revision in
                    if mode == 0 { throw StorageError.injectedFailure }
                    if mode == 1 { throw StorageError.sqlite(5, "rejected") }
                    _ = try await library.performSleepObservation(command, expectedRevision: revision)
                    throw LibraryAccessError.publicationIndeterminate
                }
                if waking {
                    await model.enqueueWakeObservation(
                        generation: generation,
                        observedAt: 120
                    ).value
                } else {
                    await model.enqueueSleepObservation(generation: generation).value
                }
                #expect(model.snapshot == before && model.timerLifecycleGate.state().sleeping)
                if mode == 2 { #expect(model.availability == .blocked) }
                await model.enqueueWakeObservation(generation: generation, observedAt: 130).value
                #expect(model.snapshot == before)
                await model.close()
                try await model.open()
                let reopened = try #require(model.snapshot)
                #expect(reopened.revision == before.revision + (mode == 2 ? 1 : 0))
                await model.enqueueWakeObservation(generation: generation, observedAt: 140).value
                #expect(model.snapshot == reopened && !model.canUndoTimeReview)
                await fixture.dispose()
            }
        }
    }

    @Test func reviewAndUndoFaultsRetainOnlyPublishedReceiptsAndNeverReplay() async throws {
        for undoing in [false, true] {
            for mode in 0..<3 {
                let fixture = try await TimerFixture.make()
                let model = fixture.model
                _ = try await model.enqueueTimer(.start(taskID: fixture.first)).value
                fixture.clock.set(110)
                let generation = model.timerLifecycleGate.latchSleep()
                await model.enqueueSleepObservation(generation: generation).value
                let sleeping = try #require(model.snapshot)
                let shown = try SleepPlanner.skip(#require(sleeping.pendingSleepIntervals.first), in: sleeping)
                if undoing { _ = try await model.enqueueTimeReview(.skip(shown)).value }
                let before = try #require(model.snapshot)
                let command: TimeReviewCommand = undoing ? .undo : .skip(shown)
                model.configureTimeReview { library, command, receipt, revision, instant in
                    if mode == 0 { throw StorageError.injectedFailure }
                    if mode == 1 { throw StorageError.sqlite(5, "rejected") }
                    _ = try await library.performTimeReview(
                        command, receipt: receipt, expectedRevision: revision,
                        instant: instant)
                    throw LibraryAccessError.publicationIndeterminate
                }
                do {
                    _ = try await model.enqueueTimeReview(command).value
                    Issue.record("fault succeeded")
                } catch {}
                #expect(model.snapshot == before)
                #expect(model.canUndoTimeReview == (undoing && mode < 2))
                if mode == 2 {
                    #expect(model.availability == .blocked)
                } else if undoing {
                    model.configureTimeReview { library, command, receipt, revision, instant in
                        try await library.performTimeReview(
                            command, receipt: receipt, expectedRevision: revision,
                            instant: instant)
                    }
                    _ = try await model.enqueueTimeReview(.undo).value
                    #expect(!model.canUndoTimeReview)
                }
                let expectedRevision = before.revision + (mode == 2 || (undoing && mode < 2) ? 1 : 0)
                await model.close()
                try await model.open()
                #expect(model.snapshot?.revision == expectedRevision && !model.canUndoTimeReview)
                await model.enqueueWakeObservation(generation: generation, observedAt: 120).value
                #expect(model.snapshot?.revision == expectedRevision)
                await fixture.dispose()
            }
        }
    }
}

@Suite @MainActor struct WorkspaceModelReportsTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    @Test func reportsSampleOnceAndNeverPublishOrRegressCheckpoint() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        _ = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        fixture.clock.set(120)
        let saved = try await model.enqueueTimer(.checkpoint).value
        let warnings = model.budgetWarnings.map(\.id)
        fixture.clock.set(150)
        var reads = fixture.clock.reads
        let project = try model.projectReport(fixture.project, period: .thisWeek, calendar: calendar)
        #expect(fixture.clock.reads == reads + 1)
        #expect(project.total.provisionalSeconds == 50 && project.total.closedSeconds == 0)
        reads = fixture.clock.reads
        let week = try model.weeklyReport(containing: 150, calendar: calendar)
        #expect(fixture.clock.reads == reads + 1)
        #expect(week.total == project.total)
        #expect(model.snapshot == saved && model.budgetWarnings.map(\.id) == warnings)
        fixture.clock.set(110)
        #expect(
            try model.projectReport(fixture.project, period: .allTime, calendar: calendar)
                .total.provisionalSeconds == 20)
        #expect(model.timerStatus == .running(entryID: saved.activeTimer!.entryID))
        await fixture.dispose()
    }

    @Test func restoredPausedBlockedAndSleepLatchedReportsStayAtCheckpoint() async throws {
        for mode in 0..<4 {
            let fixture = try await TimerFixture.make()
            let model = fixture.model
            _ = try await model.enqueueTimer(.start(taskID: fixture.first)).value
            fixture.clock.set(120)
            let saved = try await model.enqueueTimer(.checkpoint).value
            fixture.clock.set(200)
            switch mode {
            case 0:
                await model.close()
                try await model.open()
            case 1:
                model.configureTimer(
                    clock: { fixture.clock.read() },
                    write: { _, _, _, _, _ in
                        throw StorageError.injectedFailure
                    })
                await #expect(throws: StorageError.injectedFailure) {
                    try await model.enqueueTimer(.checkpoint).value
                }
            case 2:
                model.configureTimer(
                    clock: { fixture.clock.read() },
                    write: { _, _, _, _, _ in
                        throw LibraryAccessError.publicationIndeterminate
                    })
                await #expect(throws: LibraryAccessError.publicationIndeterminate) {
                    try await model.enqueueTimer(.checkpoint).value
                }
            default: _ = model.timerLifecycleGate.latchSleep()
            }
            let reads = fixture.clock.reads
            let project = try model.projectReport(fixture.project, period: .allTime, calendar: calendar)
            #expect(fixture.clock.reads == reads + 1)
            #expect(project.total.provisionalSeconds == 20 && project.hasOpenEntry)
            #expect(try model.weeklyReport(containing: 200, calendar: calendar).total == project.total)
            #expect(model.snapshot == saved)
            await fixture.dispose()
        }
    }

    @Test func knownPendingDoesNotSuppressPostWakeLiveReports() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        _ = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        fixture.clock.set(120)
        let generation = model.timerLifecycleGate.latchSleep()
        await model.enqueueSleepObservation(generation: generation).value
        fixture.clock.set(150)
        await model.enqueueWakeObservation(generation: generation, observedAt: 150).value
        let saved = try #require(model.snapshot)
        #expect(saved.pendingSleepIntervals.count == 1 && saved.pendingSleepIntervals[0].wakeAt == 150)
        fixture.clock.set(160)
        let reads = fixture.clock.reads
        let report = try model.projectReport(fixture.project, period: .allTime, calendar: calendar)
        #expect(fixture.clock.reads == reads + 1)
        #expect(report.total.closedSeconds == 20 && report.total.provisionalSeconds == 10)
        #expect(model.snapshot == saved)
        await fixture.dispose()
    }
}

@Suite struct EditorSnapshotComparisonTests {
    @Test func ignoresOnlyCheckpointBookkeeping() {
        let projectID = UUID()
        let taskID = UUID()
        let entryID = UUID()
        let pendingID = UUID()
        let project = Project(id: projectID, name: "Client", hourlyRate: 95, currencyCode: "EUR")
        let task = TaskRecord(id: taskID, projectID: projectID, name: "Work", budgetMinutes: 3600)
        let entry = TimeEntry(id: entryID, taskID: taskID, startAt: 100, endAt: nil)
        let timer = ActiveTimer(entryID: entryID, checkpointAt: 110)
        let pending = PendingSleepInterval(id: pendingID, taskID: taskID, sleepAt: 101, wakeAt: 102)
        func snapshot(
            schema: Int64 = 2, revision: Int64 = 1,
            projects: [Project]? = nil, tasks: [TaskRecord]? = nil,
            entries: [TimeEntry]? = nil, active: ActiveTimer? = nil,
            stopped: Bool = false, intervals: [PendingSleepInterval]? = nil
        ) -> LibrarySnapshot {
            LibrarySnapshot(
                schemaVersion: schema, revision: revision,
                projects: projects ?? [project], tasks: tasks ?? [task], entries: entries ?? [entry],
                activeTimer: stopped ? nil : (active ?? timer), pendingSleepIntervals: intervals ?? [pending])
        }
        let base = snapshot()
        let warning = TaskRecord(
            id: taskID, projectID: projectID, name: "Work", budgetMinutes: 3600,
            lastWarnedThreshold: .eighty)
        for harmless in [
            base, snapshot(revision: 2), snapshot(tasks: [warning]),
            snapshot(active: ActiveTimer(entryID: entryID, checkpointAt: 120)),
            snapshot(
                revision: 2, tasks: [warning],
                active: ActiveTimer(
                    entryID: entryID,
                    checkpointAt: 120))
        ] {
            #expect(base.editorRelevantEquals(harmless))
            #expect(harmless.editorRelevantEquals(base))
        }
        let changedProjects = [
            Project(id: UUID(), name: "Client", hourlyRate: 95, currencyCode: "EUR"),
            Project(id: projectID, name: "Renamed", hourlyRate: 95, currencyCode: "EUR"),
            Project(id: projectID, name: "Client", hourlyRate: 110, currencyCode: "EUR"),
            Project(id: projectID, name: "Client", hourlyRate: 95, currencyCode: "USD"),
            Project(id: projectID, name: "Client", hourlyRate: 95, currencyCode: "EUR", isArchived: true)
        ]
        let changedTasks = [
            TaskRecord(id: UUID(), projectID: projectID, name: "Work", budgetMinutes: 3600),
            TaskRecord(id: taskID, projectID: UUID(), name: "Work", budgetMinutes: 3600),
            TaskRecord(id: taskID, projectID: projectID, parentTaskID: UUID(), name: "Work", budgetMinutes: 3600),
            TaskRecord(id: taskID, projectID: projectID, name: "Renamed", budgetMinutes: 3600),
            TaskRecord(id: taskID, projectID: projectID, name: "Work", budgetMinutes: nil)
        ]
        let changedEntries = [
            TimeEntry(id: UUID(), taskID: taskID, startAt: 100, endAt: nil),
            TimeEntry(id: entryID, taskID: UUID(), startAt: 100, endAt: nil),
            TimeEntry(id: entryID, taskID: taskID, startAt: 99, endAt: nil),
            TimeEntry(id: entryID, taskID: taskID, startAt: 100, endAt: 120)
        ]
        let changedIntervals = [
            PendingSleepInterval(id: UUID(), taskID: taskID, sleepAt: 101, wakeAt: 102),
            PendingSleepInterval(id: pendingID, taskID: UUID(), sleepAt: 101, wakeAt: 102),
            PendingSleepInterval(id: pendingID, taskID: taskID, sleepAt: 100, wakeAt: 102),
            PendingSleepInterval(id: pendingID, taskID: taskID, sleepAt: 101, wakeAt: nil)
        ]
        let secondProject = Project(id: UUID(), name: "Other", hourlyRate: 1, currencyCode: "EUR")
        let secondTask = TaskRecord(id: UUID(), projectID: projectID, name: "Other")
        let secondEntry = TimeEntry(id: UUID(), taskID: taskID, startAt: 1, endAt: 2)
        let secondPending = PendingSleepInterval(id: UUID(), taskID: taskID, sleepAt: 3, wakeAt: 4)
        let changes =
            [
                snapshot(schema: 1), snapshot(stopped: true),
                snapshot(active: ActiveTimer(entryID: UUID(), checkpointAt: 110)),
                snapshot(projects: []), snapshot(tasks: []), snapshot(entries: []), snapshot(intervals: [])
            ]
            + changedProjects.map { snapshot(projects: [$0]) }
            + changedTasks.map { snapshot(tasks: [$0]) }
            + changedEntries.map { snapshot(entries: [$0]) }
            + changedIntervals.map { snapshot(intervals: [$0]) }
        for changed in changes {
            #expect(!base.editorRelevantEquals(changed))
            #expect(!changed.editorRelevantEquals(base))
        }
        #expect(!snapshot(stopped: true).editorRelevantEquals(base))
        #expect(
            !snapshot(projects: [project, secondProject]).editorRelevantEquals(
                snapshot(projects: [
                    secondProject,
                    project
                ])))
        #expect(!snapshot(tasks: [task, secondTask]).editorRelevantEquals(snapshot(tasks: [secondTask, task])))
        #expect(!snapshot(entries: [entry, secondEntry]).editorRelevantEquals(snapshot(entries: [secondEntry, entry])))
        #expect(
            !snapshot(intervals: [
                pending,
                secondPending
            ]).editorRelevantEquals(snapshot(intervals: [secondPending, pending])))
    }
}

private actor EditorOperationProbe {
    private(set) var paths: [String] = []
    private(set) var revisions: [Int64] = []
    private(set) var snapshotReads = 0
    private(set) var library: Library?

    func capture(_ library: Library) { self.library = library }
    func write(_ path: String, revision: Int64) {
        paths.append(path)
        revisions.append(revision)
    }
    func readSnapshot() { snapshotReads += 1 }
    func reset() {
        paths = []
        revisions = []
        snapshotReads = 0
    }
}

private func editorOperations(_ probe: EditorOperationProbe) -> WorkspaceOperations {
    var operations = WorkspaceOperations()
    operations.snapshot = { library in
        await probe.readSnapshot()
        return try await library.snapshot()
    }
    operations.perform = { library, command, revision in
        await probe.write("perform", revision: revision)
        return try await library.perform(command, expectedRevision: revision)
    }
    operations.performOwned = { library, command, revision, owned in
        await probe.write("performOwned", revision: revision)
        return try await library.performOwned(command, expectedRevision: revision, ownedTimerEntryID: owned)
    }
    operations.performBudget = { library, command, revision, owned, instant in
        await probe.write("performBudget", revision: revision)
        return try await library.performOwned(
            command, expectedRevision: revision,
            ownedTimerEntryID: owned, checkpointAt: instant)
    }
    operations.createTask = { library, request, revision, owned, instant in
        await probe.write("createTask", revision: revision)
        return try await library.createTaskOwned(
            request, expectedRevision: revision,
            ownedTimerEntryID: owned, instant: instant)
    }
    operations.createBudgetTask = { library, request, revision, owned, checkpoint in
        await probe.write("createBudgetTask", revision: revision)
        return try await library.createTaskOwned(
            request, expectedRevision: revision,
            ownedTimerEntryID: owned, instant: nil, checkpointAt: checkpoint)
    }
    return operations
}

@MainActor private func editorFixture(operations: WorkspaceOperations) async throws -> TimerFixture {
    let directory = workspaceDirectory()
    let model = WorkspaceModel(directory: directory, operations: operations)
    let clock = TimerTestClock()
    model.configureTimer(clock: { clock.read() })
    do {
        try await model.open()
        let project = UUID()
        let first = UUID()
        let second = UUID()
        _ = try await model.submit(
            .createProject(id: project, name: "Client", rate: 1, currency: "EUR"), expectedRevision: 0)
        _ = try await model.submit(
            .createTask(id: first, projectID: project, parentID: nil, name: "First"), expectedRevision: 1)
        _ = try await model.submit(
            .createTask(id: second, projectID: project, parentID: nil, name: "Second"), expectedRevision: 2)
        return TimerFixture(
            directory: directory, model: model, clock: clock,
            project: project, first: first, second: second)
    } catch {
        await model.close()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

@Suite @MainActor struct EditorQueueTests {
    @Test func availableStatesHaveConfirmedRows() async throws {
        let fixture = try await editorFixture(operations: editorOperations(EditorOperationProbe()))
        do {
            #expect(fixture.model.availability == .ready)
            #expect(fixture.model.snapshot != nil)
            _ = try await fixture.model.enqueueTimer(.start(taskID: fixture.first)).value
            #expect(fixture.model.snapshot != nil)
            await fixture.model.close()
            #expect(fixture.model.availability == .closed)
            #expect(fixture.model.snapshot == nil)
            try await fixture.model.open()
            #expect(fixture.model.availability == .reviewRequired)
            #expect(fixture.model.snapshot != nil)
            await fixture.model.close()
            try? FileManager.default.removeItem(at: fixture.directory)
        } catch {
            await fixture.model.close()
            try? FileManager.default.removeItem(at: fixture.directory)
            throw error
        }
    }

    @Test(arguments: ["performOwned", "performBudget", "create", "createAndStart"])
    func reviewedEditorBehindCheckpointUsesOneCurrentRevision(path: String) async throws {
        let probe = EditorOperationProbe()
        let fixture = try await editorFixture(operations: editorOperations(probe))
        do {
            let model = fixture.model
            let reviewed = try await model.enqueueTimer(.start(taskID: fixture.first)).value
            let gate = TimerTestBarrier()
            model.configureTimer(
                clock: { fixture.clock.read() },
                write: { library, command, revision, instant, id in
                    await gate.hold()
                    return try await library.performTimer(
                        command, expectedRevision: revision, instant: instant,
                        newEntryID: id)
                })
            await probe.reset()
            fixture.clock.set(120)
            let checkpoint = model.enqueueTimer(.checkpoint)
            await gate.wait()
            let reads = fixture.clock.reads
            let createdID = UUID()
            let editor: Task<LibrarySnapshot, Error>
            if path == "create" || path == "createAndStart" {
                let creation = model.enqueueTaskCreation(
                    TaskCreationRequest(
                        id: createdID, projectID: fixture.project, parentID: nil,
                        name: "Created", confirmMigration: false, start: path == "createAndStart"),
                    expectedRevision: reviewed.revision, reviewedSnapshot: reviewed)
                editor = Task { try await creation.value.snapshot }
            } else {
                let command: WorkspaceCommand =
                    path == "performBudget"
                    ? .editTask(id: fixture.second, name: "Edited", budgetMinutes: 100)
                    : .updateProject(
                        id: fixture.project, name: "Edited", rate: 2, currency: "EUR", confirmedPreviousCurrency: nil)
                editor = model.enqueueSubmit(command, expectedRevision: reviewed.revision, reviewedSnapshot: reviewed)
            }
            #expect(model.snapshot == reviewed)
            #expect(model.isBusy)
            await gate.release()
            let tick = try await checkpoint.value
            let saved = try await editor.value
            #expect(tick.revision == reviewed.revision + 1)
            #expect(tick.activeTimer?.checkpointAt == 120)
            #expect(reviewed.editorRelevantEquals(tick))
            #expect(saved.revision == tick.revision + 1)
            #expect(await probe.paths == [path.hasPrefix("create") ? "createTask" : path])
            #expect(await probe.revisions == [tick.revision])
            #expect(await probe.snapshotReads == 0)
            #expect(fixture.clock.reads == reads + (path == "performBudget" || path == "createAndStart" ? 1 : 0))
            if path.hasPrefix("create") {
                #expect(saved.tasks.contains { $0.id == createdID })
                if path == "createAndStart" {
                    #expect(saved.entries.contains { $0.taskID == createdID && $0.startAt == 120 && $0.endAt == nil })
                } else {
                    #expect(saved.activeTimer == tick.activeTimer)
                }
            } else {
                #expect(saved.activeTimer == tick.activeTimer)
            }
            #expect(model.snapshot == saved)
            #expect(model.issue == nil && model.availability == .ready && !model.isBusy)
            await fixture.dispose()
        } catch {
            await fixture.dispose()
            throw error
        }
    }

    @Test func reviewedIdleSubmitUsesPerformOnce() async throws {
        let probe = EditorOperationProbe()
        let fixture = try await editorFixture(operations: editorOperations(probe))
        do {
            let before = try #require(fixture.model.snapshot)
            await probe.reset()
            let id = UUID()
            let saved = try await fixture.model.enqueueSubmit(
                .createProject(id: id, name: "New", rate: 0, currency: "EUR"),
                expectedRevision: -1, reviewedSnapshot: before
            ).value
            #expect(saved.projects.contains { $0.id == id })
            #expect(saved.revision == before.revision + 1)
            #expect(await probe.paths == ["perform"])
            #expect(await probe.revisions == [before.revision])
            #expect(await probe.snapshotReads == 0)
            await fixture.dispose()
        } catch {
            await fixture.dispose()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func queuedRenameRejectsBeforeEditorSamplingOrWrite(creating: Bool) async throws {
        let probe = EditorOperationProbe()
        let gate = WorkspaceTestGate()
        var operations = editorOperations(probe)
        operations.performOwned = { library, command, revision, owned in
            await probe.write("performOwned", revision: revision)
            if case .renameTask = command { await gate.hold() }
            return try await library.performOwned(command, expectedRevision: revision, ownedTimerEntryID: owned)
        }
        let fixture = try await editorFixture(operations: operations)
        do {
            let model = fixture.model
            let reviewed = try await model.enqueueTimer(.start(taskID: fixture.first)).value
            let rename = model.enqueueSubmit(
                .renameTask(id: fixture.second, name: "Changed first"), expectedRevision: reviewed.revision)
            await gate.waitUntilEntered()
            // Exclude the already-entered predecessor: every remaining attempt would be an editor write.
            await probe.reset()
            let reads = fixture.clock.reads
            let editor: Task<LibrarySnapshot, Error>
            if creating {
                let work = model.enqueueTaskCreation(
                    TaskCreationRequest(
                        id: UUID(), projectID: fixture.project, parentID: nil,
                        name: "Must not exist", confirmMigration: false, start: true),
                    expectedRevision: reviewed.revision, reviewedSnapshot: reviewed)
                editor = Task { try await work.value.snapshot }
            } else {
                editor = model.enqueueSubmit(
                    .editTask(id: fixture.first, name: "Must not save", budgetMinutes: 1),
                    expectedRevision: reviewed.revision, reviewedSnapshot: reviewed)
            }
            await gate.release()
            let renamed = try await rename.value
            await #expect(throws: EditorReviewError.changed) { try await editor.value }
            #expect(!reviewed.editorRelevantEquals(renamed))
            #expect(await probe.paths.isEmpty)
            #expect(await probe.revisions.isEmpty)
            #expect(await probe.snapshotReads == 0)
            #expect(fixture.clock.reads == reads)
            #expect(model.snapshot == renamed && model.issue == .revisionConflict)
            #expect(model.availability == .ready && !model.isBusy)
            let activeID = try #require(renamed.activeTimer?.entryID)
            #expect(model.timerStatus == .running(entryID: activeID))
            #expect(renamed.tasks.first { $0.id == fixture.first }?.name == "First")
            await fixture.dispose()
        } catch {
            await gate.release()
            await fixture.dispose()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func reviewMismatchDoesNotReadUnavailableLibrary(creating: Bool) async throws {
        let probe = EditorOperationProbe()
        var operations = editorOperations(probe)
        operations.open = { directory in
            let library = try await Library.open(at: directory)
            await probe.capture(library)
            return library
        }
        let fixture = try await editorFixture(operations: operations)
        do {
            let model = fixture.model
            let reviewed = try await model.enqueueTimer(.start(taskID: fixture.first)).value
            let renamed = try await model.submit(
                .renameTask(id: fixture.second, name: "Changed"),
                expectedRevision: reviewed.revision)
            let library = try #require(await probe.library)
            await library.close()
            await #expect(throws: LibraryAccessError.unavailable) { try await library.migrationUndoAvailability() }
            await probe.reset()
            let reads = fixture.clock.reads
            let editor: Task<LibrarySnapshot, Error>
            if creating {
                let work = model.enqueueTaskCreation(
                    TaskCreationRequest(
                        id: UUID(), projectID: fixture.project, parentID: nil,
                        name: "Must not exist", confirmMigration: false, start: true),
                    expectedRevision: reviewed.revision, reviewedSnapshot: reviewed)
                editor = Task { try await work.value.snapshot }
            } else {
                editor = model.enqueueSubmit(
                    .editTask(id: fixture.first, name: "Must not save", budgetMinutes: 1),
                    expectedRevision: reviewed.revision, reviewedSnapshot: reviewed)
            }
            await #expect(throws: EditorReviewError.changed) { try await editor.value }
            #expect(await probe.paths.isEmpty)
            #expect(await probe.snapshotReads == 0)
            #expect(fixture.clock.reads == reads)
            #expect(model.snapshot == renamed && model.issue == .revisionConflict)
            #expect(model.availability == .ready && !model.isBusy)
            let activeID = try #require(renamed.activeTimer?.entryID)
            #expect(model.timerStatus == .running(entryID: activeID))
            await fixture.dispose()
        } catch {
            await fixture.dispose()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func revisionOnlyEditorBehindCheckpointStillConflicts(creating: Bool) async throws {
        let probe = EditorOperationProbe()
        let fixture = try await editorFixture(operations: editorOperations(probe))
        do {
            let model = fixture.model
            let before = try await model.enqueueTimer(.start(taskID: fixture.first)).value
            let gate = TimerTestBarrier()
            model.configureTimer(
                clock: { fixture.clock.read() },
                write: { library, command, revision, instant, id in
                    await gate.hold()
                    return try await library.performTimer(
                        command, expectedRevision: revision, instant: instant,
                        newEntryID: id)
                })
            await probe.reset()
            fixture.clock.set(120)
            let checkpoint = model.enqueueTimer(.checkpoint)
            await gate.wait()
            let editor: Task<LibrarySnapshot, Error>
            if creating {
                let work = model.enqueueTaskCreation(
                    TaskCreationRequest(
                        id: UUID(), projectID: fixture.project, parentID: nil,
                        name: "Stale", confirmMigration: false, start: false),
                    expectedRevision: before.revision)
                editor = Task { try await work.value.snapshot }
            } else {
                editor = model.enqueueSubmit(
                    .updateProject(
                        id: fixture.project, name: "Stale", rate: 2,
                        currency: "EUR", confirmedPreviousCurrency: nil), expectedRevision: before.revision)
            }
            await gate.release()
            let tick = try await checkpoint.value
            await #expect(throws: StorageError.revisionConflict(expected: before.revision, actual: tick.revision)) {
                try await editor.value
            }
            #expect(await probe.paths == [creating ? "createTask" : "performOwned"])
            #expect(await probe.revisions == [before.revision])
            #expect(await probe.snapshotReads == 1)
            #expect(model.snapshot == tick && model.issue == .revisionConflict)
            #expect(model.availability == .ready)
            await fixture.dispose()
        } catch {
            await fixture.dispose()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func storageConflictAfterReviewRefreshesWithoutReplay(creating: Bool) async throws {
        let probe = EditorOperationProbe()
        var operations = editorOperations(probe)
        operations.perform = { library, command, revision in
            await probe.write("perform", revision: revision)
            if case .updateProject(let id, _, _, _, _) = command {
                _ = try await library.perform(
                    .updateProject(
                        id: id, name: "External", rate: 3,
                        currency: "EUR", confirmedPreviousCurrency: nil), expectedRevision: revision)
            }
            return try await library.perform(command, expectedRevision: revision)
        }
        operations.createTask = { library, request, revision, owned, instant in
            await probe.write("createTask", revision: revision)
            _ = try await library.perform(
                .updateProject(
                    id: request.projectID, name: "External", rate: 3,
                    currency: "EUR", confirmedPreviousCurrency: nil), expectedRevision: revision)
            return try await library.createTaskOwned(
                request, expectedRevision: revision,
                ownedTimerEntryID: owned, instant: instant)
        }
        let directory = workspaceDirectory()
        let model = WorkspaceModel(directory: directory, operations: operations)
        do {
            try await model.open()
            let projectID = UUID()
            var before = try await model.submit(
                .createProject(
                    id: projectID, name: "Client", rate: 1,
                    currency: "EUR"), expectedRevision: 0)
            await probe.reset()
            let editor: Task<LibrarySnapshot, Error>
            let newID = UUID()
            if creating {
                let work = model.enqueueTaskCreation(
                    TaskCreationRequest(
                        id: newID, projectID: projectID, parentID: nil,
                        name: "Editor", confirmMigration: false, start: false),
                    expectedRevision: before.revision, reviewedSnapshot: before)
                editor = Task { try await work.value.snapshot }
            } else {
                editor = model.enqueueSubmit(
                    .updateProject(
                        id: projectID, name: "Editor", rate: 2,
                        currency: "EUR", confirmedPreviousCurrency: nil), expectedRevision: before.revision,
                    reviewedSnapshot: before)
            }
            await #expect(
                throws: StorageError.revisionConflict(
                    expected: before.revision,
                    actual: before.revision + 1)
            ) {
                try await editor.value
            }
            #expect(await probe.paths == [creating ? "createTask" : "perform"])
            #expect(await probe.revisions == [before.revision])
            #expect(await probe.snapshotReads == 1)
            before = try #require(model.snapshot)
            #expect(before.revision == 2)
            #expect(before.projects.first?.name == "External")
            #expect(!before.tasks.contains { $0.id == newID })
            #expect(model.issue == .revisionConflict && model.availability == .ready)
            await model.close()
            try? FileManager.default.removeItem(at: directory)
        } catch {
            await model.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    @Test(arguments: [false, true])
    func reviewedPublicationFailureStillBlocksWithoutReplay(creating: Bool) async throws {
        let probe = EditorOperationProbe()
        var operations = editorOperations(probe)
        operations.perform = { library, command, revision in
            await probe.write("perform", revision: revision)
            let saved = try await library.perform(command, expectedRevision: revision)
            if case .updateProject = command { throw LibraryAccessError.publicationIndeterminate }
            return saved
        }
        operations.createTask = { library, request, revision, owned, instant in
            await probe.write("createTask", revision: revision)
            _ = try await library.createTaskOwned(
                request, expectedRevision: revision,
                ownedTimerEntryID: owned, instant: instant)
            throw LibraryAccessError.publicationIndeterminate
        }
        let fixture = try await editorFixture(operations: operations)
        do {
            let model = fixture.model
            let before = try #require(fixture.model.snapshot)
            let newID = UUID()
            await probe.reset()
            let editor: Task<LibrarySnapshot, Error>
            if creating {
                let work = model.enqueueTaskCreation(
                    TaskCreationRequest(
                        id: newID, projectID: fixture.project, parentID: nil,
                        name: "Once", confirmMigration: false, start: false),
                    expectedRevision: before.revision, reviewedSnapshot: before)
                editor = Task { try await work.value.snapshot }
            } else {
                editor = model.enqueueSubmit(
                    .updateProject(
                        id: fixture.project, name: "Once", rate: 2,
                        currency: "EUR", confirmedPreviousCurrency: nil), expectedRevision: before.revision,
                    reviewedSnapshot: before)
            }
            await #expect(throws: LibraryAccessError.publicationIndeterminate) { try await editor.value }
            #expect(await probe.paths == [creating ? "createTask" : "perform"])
            #expect(await probe.revisions == [before.revision])
            #expect(await probe.snapshotReads == 0)
            #expect(model.snapshot == before && model.availability == .blocked && model.issue == .uncertainSave)
            try await model.open()
            let reopened = try #require(model.snapshot)
            #expect(reopened.revision == before.revision + 1)
            if creating {
                #expect(reopened.tasks.filter { $0.id == newID }.count == 1)
            } else {
                #expect(reopened.projects.first { $0.id == fixture.project }?.name == "Once")
            }
            #expect(await probe.paths.count == 1)
            await fixture.dispose()
        } catch {
            await fixture.dispose()
            throw error
        }
    }
}

extension WorkspaceModelTests {
    @Test func requireTimerReviewAfterCloseNilSnapshotAndBlockedStateNoWriteReplay() async throws {
        let directory = workspaceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Nil snapshot path: close first, then require review; must not mutate closed state.
        let closed = WorkspaceModel(directory: directory)
        try await closed.open()
        await closed.close()
        let closedGeneration = closed.timerLifecycleGate.currentGeneration
        closed.requireTimerReviewAfterClose(sleeping: false)
        #expect(closed.availability == .closed)
        #expect(closed.snapshot == nil)
        #expect(closed.timerLifecycleGate.currentGeneration == closedGeneration)

        // Blocked path via real failure classification (no fake setters).
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let started = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        final class WriteCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func record() {
                lock.lock()
                count += 1
                lock.unlock()
            }
            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }
        let writes = WriteCounter()
        let clock = fixture.clock
        clock.set(105)
        model.configureTimer(
            clock: { clock.read() },
            write: { _, _, _, _, _ in
                writes.record()
                throw StorageError.invalidStorage("blocked")
            })
        await #expect(throws: StorageError.invalidStorage("blocked")) {
            try await model.enqueueTimer(.checkpoint).value
        }
        #expect(model.availability == .blocked)
        #expect(model.snapshot == started)
        let before = writes.value
        model.requireTimerReviewAfterClose(sleeping: false)
        #expect(model.availability == .blocked)
        #expect(model.snapshot == started)
        #expect(writes.value == before)  // no replay/write side effect
        await fixture.dispose()
    }

    @Test func requireTimerReviewAfterCloseRepeatedCallPreservesNextSleepLatch() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model

        let started = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        #expect(model.timerStatus == .running(entryID: try #require(started.activeTimer).entryID))

        model.timerLifecycleGate.latchSleep()
        model.requireTimerReviewAfterClose(sleeping: true)
        #expect(model.timerStatus == .reviewRequired)
        #expect(model.timerLifecycleGate.state().sleeping)

        // Repeated call after physical wake clears stale latch but keeps review-required ownership semantics.
        model.requireTimerReviewAfterClose(sleeping: false)
        #expect(model.timerStatus == .reviewRequired)
        #expect(!model.timerLifecycleGate.state().sleeping)

        // Next real sleep must still latch with timer new generation.
        let generation = model.timerLifecycleGate.currentGeneration
        let next = model.timerLifecycleGate.latchSleep()
        #expect(next > generation)
        #expect(model.timerLifecycleGate.state().generation == next)
        #expect(model.timerLifecycleGate.state().sleeping)
        #expect(throws: TimerError.reviewRequired) {
            try model.timerLifecycleGate.sample(clock: { 120 })
        }

        await fixture.dispose()
    }
}

extension WorkspaceModelTests {
    @Test func budgetedCreationCheckpointsOnceAndScopesThroughWorkspace() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        do {
            let running = try await model.enqueueTimer(.start(taskID: fixture.first)).value
            fixture.clock.set(160)
            let reads = fixture.clock.reads
            let request = TaskCreationRequest(
                id: UUID(), projectID: fixture.project, parentID: fixture.first,
                name: "Budget child", budgetMinutes: 1, confirmMigration: true, start: false)
            let result = try await model.enqueueTaskCreation(
                request, expectedRevision: running.revision,
                reviewedSnapshot: running
            ).value
            #expect(fixture.clock.reads == reads + 1)
            #expect(result.snapshot.revision == running.revision + 1)
            #expect(result.snapshot.activeTimer?.entryID == running.activeTimer?.entryID)
            #expect(result.snapshot.activeTimer?.checkpointAt == 160)
            #expect(result.snapshot.tasks.first { $0.id == request.id }?.budgetMinutes == 1)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let report = try model.projectReport(
                fixture.project, period: .allTime, calendar: calendar,
                scopeTaskID: request.id)
            #expect(report.scopeTask?.id == request.id && report.total == .zero && !report.hasOpenEntry)
            #expect(model.snapshot == result.snapshot)
            await fixture.dispose()
        } catch {
            await fixture.dispose()
            throw error
        }
    }

    @Test func reviewedBudgetedCreationRebasesAfterCheckpointWithoutResamplingPredecessor() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let barrier = TimerTestBarrier()
        do {
            let reviewed = try await model.enqueueTimer(.start(taskID: fixture.first)).value
            model.configureTimer(
                clock: { fixture.clock.read() },
                write: { library, command, revision, instant, id in
                    await barrier.hold()
                    return try await library.performTimer(
                        command, expectedRevision: revision, instant: instant,
                        newEntryID: id)
                })
            fixture.clock.set(120)
            let tick = model.enqueueTimer(.checkpoint)
            await barrier.wait()
            let reads = fixture.clock.reads
            let request = TaskCreationRequest(
                id: UUID(), projectID: fixture.project, parentID: nil,
                name: "Budgeted", budgetMinutes: 30, confirmMigration: false, start: false)
            let work = model.enqueueTaskCreation(
                request, expectedRevision: reviewed.revision,
                reviewedSnapshot: reviewed)
            work.cancel()
            fixture.clock.set(130)
            await barrier.release()
            let checkpoint = try await tick.value
            let saved = try await work.value
            #expect(reviewed.editorRelevantEquals(checkpoint))
            #expect(saved.snapshot.revision == checkpoint.revision + 1)
            #expect(saved.snapshot.activeTimer?.checkpointAt == 130)
            #expect(fixture.clock.reads == reads + 1)
            #expect(saved.snapshot.tasks.contains { $0.id == request.id && $0.budgetMinutes == 30 })
            await fixture.dispose()
        } catch {
            await barrier.release()
            await fixture.dispose()
            throw error
        }
    }
}

extension EditorQueueTests {
    @Test(arguments: [0, 1, 2])
    func sampledCreationFailuresPauseAndNeverReplay(mode: Int) async throws {
        let probe = EditorOperationProbe()
        var operations = editorOperations(probe)
        operations.createBudgetTask = { library, request, revision, owned, checkpoint in
            await probe.write("createBudgetTask", revision: revision)
            if mode == 0 { throw StorageError.injectedFailure }
            if mode == 1 { throw StorageError.sqlite(1, "rejected creation") }
            _ = try await library.createTaskOwned(
                request, expectedRevision: revision,
                ownedTimerEntryID: owned, instant: nil, checkpointAt: checkpoint)
            throw LibraryAccessError.publicationIndeterminate
        }
        let fixture = try await editorFixture(operations: operations)
        do {
            let model = fixture.model
            let before = try await model.enqueueTimer(.start(taskID: fixture.first)).value
            let entry = try #require(before.activeTimer?.entryID)
            let request = TaskCreationRequest(
                id: UUID(), projectID: fixture.project, parentID: nil,
                name: "Once", budgetMinutes: 1, confirmMigration: false, start: false)
            await probe.reset()
            fixture.clock.set(160)
            let reads = fixture.clock.reads
            do {
                _ = try await model.enqueueTaskCreation(request, expectedRevision: before.revision).value
                Issue.record("injected creation succeeded")
            } catch {}
            #expect(await probe.paths == ["createBudgetTask"])
            #expect(await probe.revisions == [before.revision])
            #expect(fixture.clock.reads == reads + 1)
            #expect(model.snapshot == before && model.budgetWarnings.isEmpty)
            #expect(model.timerStatus == .paused(entryID: entry) || model.availability == .blocked)
            #expect(model.availability == (mode == 2 ? .blocked : .ready))
            if mode == 2 {
                await #expect(throws: LibraryAccessError.unavailable) {
                    try await model.enqueueTaskCreation(request, expectedRevision: before.revision).value
                }
                #expect(await probe.paths == ["createBudgetTask"])
            }
            await model.close()
            try await model.open()
            let reopened = try #require(model.snapshot)
            #expect(reopened.revision == before.revision + (mode == 2 ? 1 : 0))
            #expect(reopened.tasks.filter { $0.id == request.id }.count == (mode == 2 ? 1 : 0))
            #expect(reopened.activeTimer?.checkpointAt == (mode == 2 ? 160 : 100))
            #expect(model.budgetWarnings.isEmpty)
            #expect(await probe.paths == ["createBudgetTask"])
            await fixture.dispose()
        } catch {
            await fixture.dispose()
            throw error
        }
    }

    @Test func creationAllocationFailureRollsBackCheckpointAndPauses() async throws {
        let fixture = try await editorFixture(operations: editorOperations(EditorOperationProbe()))
        do {
            let model = fixture.model
            let initial = try #require(model.snapshot)
            _ = try await model.submit(
                .editTask(id: fixture.first, name: "First", budgetMinutes: 1),
                expectedRevision: initial.revision)
            let before = try await model.enqueueTimer(.start(taskID: fixture.first)).value
            let id = try #require(before.activeTimer?.entryID)
            fixture.clock.set(160)
            let reads = fixture.clock.reads
            let request = TaskCreationRequest(
                id: UUID(), projectID: fixture.project, parentID: fixture.first,
                name: "Too large", budgetMinutes: 2, confirmMigration: true, start: false)
            do {
                _ = try await model.enqueueTaskCreation(request, expectedRevision: before.revision).value
                Issue.record("allocation accepted")
            } catch CommandError.budgetAllocation(let task, let allowance) {
                #expect(task == request.id && allowance.maximumMinutes == 1)
                #expect(allowance.limitingAncestorID == fixture.first)
            }
            #expect(fixture.clock.reads == reads + 1)
            #expect(model.snapshot == before && model.budgetWarnings.isEmpty)
            #expect(model.timerStatus == .paused(entryID: id))
            await model.close()
            try await model.open()
            #expect(model.snapshot == before)
            await fixture.dispose()
        } catch {
            await fixture.dispose()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func budgetCreationRejectsQueuedEditorOrGenerationChange(editorChange: Bool) async throws {
        let probe = EditorOperationProbe()
        let barrier = TimerTestBarrier()
        var operations = editorOperations(probe)
        operations.performOwned = { library, command, revision, owned in
            await barrier.hold()
            return try await library.performOwned(command, expectedRevision: revision, ownedTimerEntryID: owned)
        }
        let fixture = try await editorFixture(operations: operations)
        do {
            let model = fixture.model
            let reviewed = try await model.enqueueTimer(.start(taskID: fixture.first)).value
            // An unchanged rename supplies timer FIFO barrier without changing editor state.
            let predecessor = model.enqueueSubmit(
                .renameTask(
                    id: fixture.second,
                    name: editorChange ? "Changed" : "Second"), expectedRevision: reviewed.revision)
            await barrier.wait()
            await probe.reset()
            let request = TaskCreationRequest(
                id: UUID(), projectID: fixture.project, parentID: nil,
                name: "Rejected", budgetMinutes: 1, confirmMigration: false, start: false)
            let work = model.enqueueTaskCreation(
                request, expectedRevision: reviewed.revision,
                reviewedSnapshot: reviewed)
            if !editorChange {
                let generation = model.timerLifecycleGate.latchSleep()
                #expect(model.timerLifecycleGate.reset(generation: generation))
            }
            let reads = fixture.clock.reads
            await barrier.release()
            let saved = try await predecessor.value
            if editorChange {
                await #expect(throws: EditorReviewError.changed) { try await work.value }
                #expect(fixture.clock.reads == reads)
            } else {
                await #expect(throws: TimerError.reviewRequired) { try await work.value }
                #expect(fixture.clock.reads == reads + 1)
            }
            #expect(await probe.paths.isEmpty)
            #expect(model.snapshot == saved)
            #expect(!saved.tasks.contains { $0.id == request.id })
            await fixture.dispose()
        } catch {
            await barrier.release()
            await fixture.dispose()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func pausedOrSleepingBudgetCreationNeverSamples(sleeping: Bool) async throws {
        let probe = EditorOperationProbe()
        let fixture = try await editorFixture(operations: editorOperations(probe))
        do {
            let model = fixture.model
            let started = try await model.enqueueTimer(.start(taskID: fixture.first)).value
            if sleeping {
                _ = model.timerLifecycleGate.latchSleep()
            } else {
                fixture.clock.set(99)
                await #expect(throws: TimerError.clockRollback) { try await model.enqueueTimer(.checkpoint).value }
            }
            await probe.reset()
            let reads = fixture.clock.reads
            let request = TaskCreationRequest(
                id: UUID(), projectID: fixture.project, parentID: nil,
                name: "Saved prefix only", budgetMinutes: 1, confirmMigration: false, start: false)
            let result = try await model.enqueueTaskCreation(request, expectedRevision: started.revision).value
            #expect(fixture.clock.reads == reads)
            #expect(await probe.paths == ["createTask"])
            #expect(result.snapshot.activeTimer == started.activeTimer)
            #expect(result.snapshot.tasks.first { $0.id == request.id }?.budgetMinutes == 1)
            if sleeping { #expect(model.timerLifecycleGate.state().sleeping) }
            await fixture.dispose()
        } catch {
            await fixture.dispose()
            throw error
        }
    }

    @Test func sampledCreationDrainsBeforeQueuedClose() async throws {
        let probe = EditorOperationProbe()
        let barrier = TimerTestBarrier()
        var operations = editorOperations(probe)
        operations.createBudgetTask = { library, request, revision, owned, checkpoint in
            await probe.write("createBudgetTask", revision: revision)
            await barrier.hold()
            return try await library.createTaskOwned(
                request, expectedRevision: revision,
                ownedTimerEntryID: owned, instant: nil, checkpointAt: checkpoint)
        }
        let fixture = try await editorFixture(operations: operations)
        do {
            let model = fixture.model
            let before = try await model.enqueueTimer(.start(taskID: fixture.first)).value
            fixture.clock.set(160)
            await probe.reset()
            let reads = fixture.clock.reads
            let request = TaskCreationRequest(
                id: UUID(), projectID: fixture.project, parentID: nil,
                name: "Drain sampled write", budgetMinutes: 1, confirmMigration: false, start: false)
            let work = model.enqueueTaskCreation(request, expectedRevision: before.revision)
            await barrier.wait()
            let close = model.enqueueClose()
            await #expect(throws: LibraryAccessError.unavailable) {
                try await model.enqueueTaskCreation(request, expectedRevision: before.revision).value
            }
            await barrier.release()
            let result = try await work.value
            await close.value
            #expect(result.snapshot.activeTimer?.checkpointAt == 160)
            #expect(result.snapshot.revision == before.revision + 1)
            #expect(model.availability == .closed && model.snapshot == nil)
            #expect(fixture.clock.reads == reads + 1)
            #expect(await probe.paths == ["createBudgetTask"])
            try await model.open()
            #expect(model.snapshot == result.snapshot)
            #expect(model.snapshot?.tasks.filter { $0.id == request.id }.count == 1)
            await fixture.dispose()
        } catch {
            await barrier.release()
            await fixture.dispose()
            throw error
        }
    }

    @Test func sampledCreationPreservesLaterSleepAndDrainsBeforeClose() async throws {
        let probe = EditorOperationProbe()
        let barrier = TimerTestBarrier()
        var operations = editorOperations(probe)
        operations.createBudgetTask = { library, request, revision, owned, checkpoint in
            await probe.write("createBudgetTask", revision: revision)
            await barrier.hold()
            return try await library.createTaskOwned(
                request, expectedRevision: revision,
                ownedTimerEntryID: owned, instant: nil, checkpointAt: checkpoint)
        }
        let fixture = try await editorFixture(operations: operations)
        do {
            let model = fixture.model
            let before = try await model.enqueueTimer(.start(taskID: fixture.first)).value
            fixture.clock.set(160)
            await probe.reset()
            let reads = fixture.clock.reads
            let request = TaskCreationRequest(
                id: UUID(), projectID: fixture.project, parentID: nil,
                name: "Accepted", budgetMinutes: 1, confirmMigration: false, start: false)
            let work = model.enqueueTaskCreation(request, expectedRevision: before.revision)
            await barrier.wait()
            let generation = model.timerLifecycleGate.latchSleep()
            await barrier.release()
            let result = try await work.value
            #expect(model.timerLifecycleGate.state().generation == generation)
            #expect(model.timerLifecycleGate.state().sleeping)
            #expect(result.snapshot.activeTimer?.checkpointAt == 160)
            // A second accepted saved-prefix creation queues before close; close must drain it.
            let second = TaskCreationRequest(
                id: UUID(), projectID: fixture.project, parentID: nil,
                name: "Before close", budgetMinutes: 1, confirmMigration: false, start: false)
            let accepted = model.enqueueTaskCreation(second, expectedRevision: result.snapshot.revision)
            let close = model.enqueueClose()
            let saved = try await accepted.value
            await close.value
            #expect(model.availability == .closed && model.snapshot == nil)
            // One read for the creation sample, one for latchSleep'statement observation boundary.
            #expect(fixture.clock.reads == reads + 2)
            #expect(await probe.paths == ["createBudgetTask", "createTask"])
            try await model.open()
            #expect(model.snapshot == saved.snapshot)
            #expect(model.snapshot?.tasks.filter { $0.id == request.id || $0.id == second.id }.count == 2)
            await fixture.dispose()
        } catch {
            await barrier.release()
            await fixture.dispose()
            throw error
        }
    }
}
