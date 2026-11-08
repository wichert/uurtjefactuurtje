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
        value = try await model.submit(.createTask(id: parent, projectID: fixture.project, parentID: nil,
            name: "Budget root", budgetSeconds: 100), expectedRevision: value.revision)
        let leaf = UUID()
        value = try await model.submit(.createTask(id: leaf, projectID: fixture.project, parentID: parent,
            name: "Budget leaf", budgetSeconds: 100), expectedRevision: value.revision)
        fixture.clock.set(1000)
        let started = try await model.enqueueTimer(.start(taskID: leaf)).value
        fixture.clock.set(999)
        #expect(try model.timerElapsedSeconds() == 0)
        #expect(try model.budgetUsage()[parent] == 0)
        #expect(model.snapshot == started)
        fixture.clock.set(1080)
        let reads = fixture.clock.reads
        #expect(try model.timerElapsedSeconds() == 80)
        #expect(try model.budgetUsage()[parent] == 80)
        #expect(model.snapshot == started)
        #expect(model.budgetWarnings.isEmpty)
        #expect(fixture.clock.reads == reads + 2)
        let saved = try await model.submit(.editTask(id: leaf, name: "Saved", budgetSeconds: 80),
                                           expectedRevision: started.revision)
        #expect(saved.revision == started.revision + 1)
        #expect(saved.activeTimer?.checkpointAt == 1080)
        #expect(saved.tasks.first { $0.id == leaf }?.name == "Saved")
        let batch = try #require(model.budgetWarnings.first)
        #expect(batch.warnings.map(\.taskID) == [parent, leaf].sorted { $0.uuidString < $1.uuidString })
        #expect(batch.warnings.first { $0.taskID == parent }?.threshold == .eighty)
        #expect(batch.warnings.first { $0.taskID == leaf }?.threshold == .hundred)
        _ = try await model.enqueueTimer(.checkpoint).value
        #expect(model.budgetWarnings.count == 1)
        model.dismissBudgetWarning(batch.id)
        let renamed = try await model.submit(.renameTask(id: leaf, name: "Rename only"), expectedRevision: saved.revision)
        #expect(renamed.tasks.first { $0.id == leaf }?.budgetSeconds == 80)
        let reset = try await model.submit(.editTask(id: leaf, name: "Unset", budgetSeconds: nil), expectedRevision: renamed.revision)
        #expect(model.budgetWarnings.isEmpty)
        let enabled = try await model.submit(.editTask(id: leaf, name: "Enabled", budgetSeconds: 50), expectedRevision: reset.revision)
        #expect(model.budgetWarnings.count == 1)
        #expect(model.budgetWarnings[0].warnings == [BudgetWarning(taskID: leaf, threshold: .hundred)])
        fixture.clock.set(1081)
        do {
            _ = try await model.submit(.editTask(id: leaf, name: "Too large", budgetSeconds: 101), expectedRevision: enabled.revision)
            Issue.record("allocation unexpectedly succeeded")
        } catch CommandError.budgetAllocation(let id, let allowance) {
            #expect(id == leaf)
            #expect(allowance.limitingAncestorID == parent)
            #expect(allowance.maximumSeconds == 100)
        }
        #expect(model.snapshot == enabled)
        #expect(model.timerStatus == .paused(entryID: enabled.activeTimer!.entryID))
        let pausedReads = fixture.clock.reads
        #expect(try model.timerElapsedSeconds() == 80)
        #expect(try model.budgetUsage()[parent] == 80)
        #expect(fixture.clock.reads == pausedReads)
        await model.close()
        try await model.open()
        #expect(model.budgetWarnings.isEmpty)
        #expect(try model.timerElapsedSeconds() == 80)
        #expect(try model.budgetUsage()[leaf] == 80)
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
        let first = model.enqueueSubmit(.editTask(id: fixture.first, name: "One", budgetSeconds: 1), expectedRevision: started.revision)
        let stale = model.enqueueSubmit(.editTask(id: fixture.first, name: "Stale", budgetSeconds: 2), expectedRevision: started.revision)
        let saved = try await first.value
        do { _ = try await stale.value; Issue.record("stale form succeeded") }
        catch StorageError.revisionConflict { }
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
        let project = UUID(), leaf = UUID()
        _ = try await model.submit(.createProject(id: project, name: "Client", rate: 1, currency: "EUR"), expectedRevision: 0)
        _ = try await model.submit(.createTask(id: leaf, projectID: project, parentID: nil, name: "Leaf", budgetSeconds: 1), expectedRevision: 1)
        let started = try await model.enqueueTimer(.start(taskID: leaf)).value
        let rename = model.enqueueSubmit(.renameTask(id: leaf, name: "First"), expectedRevision: started.revision)
        await barrier.wait()
        let edit = model.enqueueSubmit(.editTask(id: leaf, name: "Second", budgetSeconds: 2), expectedRevision: started.revision + 1)
        let reads = clock.reads
        let gate = model.timerLifecycleGate
        let generation = await Task.detached { gate.latchSleep() }.value
        clock.set(9000)
        await barrier.release()
        _ = try await rename.value
        let saved = try await edit.value
        #expect(saved.activeTimer == started.activeTimer)
        #expect(clock.reads == reads + 1) // latchSleep itself captures one receipt-time boundary.
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
                _ = try await library.performOwned(command, expectedRevision: revision,
                    ownedTimerEntryID: owned, checkpointAt: instant)
                throw LibraryAccessError.publicationIndeterminate
            }
            let model = WorkspaceModel(directory: directory, operations: operations)
            model.configureTimer(clock: { clock.read() })
            try await model.open()
            let project = UUID(), leaf = UUID()
            _ = try await model.submit(.createProject(id: project, name: "Client", rate: 1, currency: "EUR"), expectedRevision: 0)
            _ = try await model.submit(.createTask(id: leaf, projectID: project, parentID: nil, name: "Leaf"), expectedRevision: 1)
            let before = try await model.enqueueTimer(.start(taskID: leaf)).value
            clock.set(1100)
            do {
                _ = try await model.submit(.editTask(id: leaf, name: "Crossed", budgetSeconds: 50), expectedRevision: before.revision)
                Issue.record("fault returned success")
            } catch { }
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
        let firstConsumer = model, secondConsumer = model
        try await model.open()
        let project = UUID(), draft = "Stale draft"
        let first = firstConsumer.enqueueSubmit(.createProject(id: project, name: "Client", rate: 1, currency: "EUR"), expectedRevision: 0)
        await gate.waitUntilEntered()
        let stale = secondConsumer.enqueueSubmit(.createProject(id: UUID(), name: draft, rate: 0, currency: "EUR"), expectedRevision: 0)
        stale.cancel()
        #expect(model.isBusy)
        await gate.release()
        let committed = try await first.value
        await #expect(throws: StorageError.revisionConflict(expected: 0, actual: 1)) { try await stale.value }
        #expect(firstConsumer.snapshot == committed && secondConsumer.snapshot == committed)
        #expect(model.issue == .revisionConflict && draft == "Stale draft")
        #expect(!model.isBusy)

        let beforeClose = model.enqueueSubmit(.renameTask(id: UUID(), name: "Missing"), expectedRevision: committed.revision)
        let close = model.enqueueClose()
        let rejected = model.enqueueSubmit(.setArchived(id: project, archived: true), expectedRevision: committed.revision)
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
            try await model.submit(.createProject(id: id, name: "Client", rate: 0, currency: "EUR"), expectedRevision: 0)
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
        let project = UUID(), task = UUID()
        var snapshot = try await owner.perform(.createProject(id: project, name: "Client", rate: 0, currency: "EUR"), expectedRevision: 0)
        snapshot = try await owner.perform(.createTask(id: task, projectID: project, parentID: nil, name: "Work"), expectedRevision: snapshot.revision)
        _ = try await owner.transact(expectedRevision: snapshot.revision) { db, _ in
            try db.runCommand("INSERT INTO pending_sleep_intervals(id,task_id,sleep_at,wake_at) VALUES (?,?,?,?)", bindings: [.text(UUID().uuidString.lowercased()), .text(task.uuidString.lowercased()), .integer(1), .integer(2)], expectedChanges: 1)
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
        let request = TaskCreationRequest(id: UUID(), projectID: fixture.project, parentID: fixture.first,
                                          name: "Child", confirmMigration: true, start: false)
        let creation = model.enqueueTaskCreation(request, expectedRevision: started.revision)
        guard case .unavailable = model.migrationUndoAvailability else { Issue.record("Undo enabled while mutating"); return }
        let result = try await creation.value
        #expect(result.snapshot.activeTimer == started.activeTimer)
        guard case let .available(receipt) = model.migrationUndoAvailability else { Issue.record("Undo not available"); return }
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
            return try await library.createTaskOwned(request, expectedRevision: revision, ownedTimerEntryID: owned, instant: instant)
        }
        let model = WorkspaceModel(directory: directory, operations: operations)
        model.configureTimer(clock: { 100 })
        try await model.open()
        let project = UUID(), parent = UUID()
        let created = try await model.submit(.createProject(id: project, name: "Client", rate: 0, currency: "EUR"), expectedRevision: 0)
        let before = try await model.submit(.createTask(id: parent, projectID: project, parentID: nil, name: "Parent"), expectedRevision: created.revision)
        let request = TaskCreationRequest(id: UUID(), projectID: project, parentID: parent, name: "Child", confirmMigration: true, start: true)
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
            _ = try await library.createTaskOwned(request, expectedRevision: revision, ownedTimerEntryID: owned, instant: instant)
            throw LibraryAccessError.publicationIndeterminate
        }
        let model = WorkspaceModel(directory: directory, operations: operations)
        try await model.open()
        let project = UUID(), parent = UUID()
        let created = try await model.submit(.createProject(id: project, name: "Client", rate: 0, currency: "EUR"), expectedRevision: 0)
        let before = try await model.submit(.createTask(id: parent, projectID: project, parentID: nil, name: "Parent"), expectedRevision: created.revision)
        let request = TaskCreationRequest(id: UUID(), projectID: project, parentID: parent, name: "Child", confirmMigration: true, start: false)
        await #expect(throws: LibraryAccessError.publicationIndeterminate) {
            try await model.enqueueTaskCreation(request, expectedRevision: before.revision).value
        }
        #expect(model.snapshot == before && model.availability == .blocked && model.issue == .uncertainSave)
        guard case .unavailable = model.migrationUndoAvailability else { Issue.record("Blocked workspace enabled undo"); return }
        try await model.open()
        #expect(model.snapshot?.tasks.filter { $0.id == request.id }.count == 1)
        guard case .unavailable = model.migrationUndoAvailability else { Issue.record("Reopen retained receipt"); return }
        await model.close()
    }

    @Test func pausedMigrationPreservesSleepLatch() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let started = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        let generation = model.timerLifecycleGate.latchSleep()
        let request = TaskCreationRequest(id: UUID(), projectID: fixture.project, parentID: fixture.first,
                                          name: "Child", confirmMigration: true, start: false)
        let result = try await model.enqueueTaskCreation(request, expectedRevision: started.revision).value
        #expect(result.snapshot.activeTimer == started.activeTimer)
        #expect(model.timerLifecycleGate.state().sleeping)
        #expect(model.timerStatus == .paused(entryID: started.activeTimer!.entryID))
        guard case let .available(receipt) = model.migrationUndoAvailability else { Issue.record("Paused migration not undoable"); return }
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
        let request = TaskCreationRequest(id: UUID(), projectID: fixture.project, parentID: fixture.first,
                                          name: "Child", confirmMigration: true, start: false)
        _ = try await model.enqueueTaskCreation(request, expectedRevision: started.revision).value
        guard case let .available(receipt) = model.migrationUndoAvailability else { Issue.record("Undo not available"); return }
        fixture.clock.set(110)
        let checkpoint = model.enqueueTimer(.checkpoint)
        guard case .unavailable = model.migrationUndoAvailability else { Issue.record("Undo enabled during checkpoint"); return }
        _ = try await checkpoint.value
        guard case .unavailable = model.migrationUndoAvailability else { Issue.record("Checkpoint did not invalidate undo"); return }
        await #expect(throws: CommandError.undoUnavailable) { try await model.enqueueMigrationUndo(receiptID: receipt).value }
        await model.close()
        try await model.open()
        guard case .unavailable = model.migrationUndoAvailability else { Issue.record("Reopen retained undo"); return }
        await fixture.dispose()
    }

    @Test func createAndStartUsesOneSampleAndOneRevision() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let started = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        fixture.clock.set(110)
        let beforeReads = fixture.clock.reads
        let request = TaskCreationRequest(id: UUID(), projectID: fixture.project, parentID: fixture.first,
                                          name: "Child", confirmMigration: true, start: true)
        let result = try await model.enqueueTaskCreation(request, expectedRevision: started.revision).value
        #expect(result.snapshot.revision == started.revision + 1 && fixture.clock.reads == beforeReads + 1)
        #expect(result.snapshot.entries.contains { $0.taskID == request.id && $0.startAt == 110 && $0.endAt == nil })
        guard case .unavailable = model.migrationUndoAvailability else { Issue.record("Started task allowed undo"); return }
        await fixture.dispose()
    }
    @Test func timerFIFOCoalescingCheckpointLimitAndClose() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let barrier = TimerTestBarrier()
        model.configureTimer(clock: { fixture.clock.read() }, write: { library, command, revision, instant, id in
            await barrier.hold()
            return try await library.performTimer(command, expectedRevision: revision, instant: instant, newEntryID: id)
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
        model.configureTimer(clock: { fixture.clock.read() }, write: { library, command, revision, instant, id in
            await barrier.hold()
            return try await library.performTimer(command, expectedRevision: revision, instant: instant, newEntryID: id)
        })
        fixture.clock.set(110)
        let switchTask = model.enqueueTimer(.start(taskID: fixture.second))
        await barrier.wait()
        let rename = model.enqueueSubmit(.renameTask(id: fixture.first, name: "Renamed"), expectedRevision: started.revision + 1)
        let afterEdit = model.enqueueTimer(.start(taskID: fixture.second))
        await barrier.release()
        let switched = try await switchTask.value
        let edited = try await rename.value
        let repeated = try await afterEdit.value
        #expect(edited.activeTimer == switched.activeTimer)
        #expect(repeated == edited && repeated.revision == switched.revision + 1)
        #expect(model.availability == .ready)
        let projectEdit = try await model.submit(.updateProject(id: fixture.project, name: "Client", rate: 42, currency: "EUR", confirmedPreviousCurrency: nil), expectedRevision: edited.revision)
        #expect(projectEdit.activeTimer == switched.activeTimer)
        await #expect(throws: CommandError.recoveryRequired) {
            try await model.submit(.setArchived(id: fixture.project, archived: true), expectedRevision: projectEdit.revision)
        }
        await #expect(throws: CommandError.migrationRequired) {
            try await model.submit(.createTask(id: UUID(), projectID: fixture.project, parentID: fixture.second, name: "Child"), expectedRevision: projectEdit.revision)
        }
        #expect(model.snapshot == projectEdit)
        await fixture.dispose()
    }

    @Test func synchronousLatchBeforeDelayedObservationUsesReceiptBoundary() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let barrier = TimerTestBarrier()
        model.configureTimer(clock: { fixture.clock.read() }, write: { library, command, revision, instant, id in
            await barrier.hold()
            return try await library.performTimer(command, expectedRevision: revision, instant: instant, newEntryID: id)
        })
        let start = model.enqueueTimer(.start(taskID: fixture.first))
        await barrier.wait() // already sampled, not yet published
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
        let fixture = try await TimerFixture.make(), model = fixture.model
        _ = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        fixture.clock.set(110)
        let first = model.timerLifecycleGate.latchSleep()
        await model.enqueueSleepObservation(generation: first).value
        let sleeping = try #require(model.snapshot), barrier = TimerTestBarrier()
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
        await #expect(throws: TimerError.reviewRequired) { try await model.enqueueTimer(.start(taskID: fixture.second)).value }
        await fixture.dispose()
    }

    @Test func failedCheckpointClearsPeriodicMarkerButKeepsPause() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        _ = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        fixture.clock.set(110)
        model.configureTimer(clock: { fixture.clock.read() }, write: { _, _, _, _, _ in throw StorageError.injectedFailure })
        await #expect(throws: StorageError.injectedFailure) { try await model.enqueueTimer(.checkpoint).value }
        // A second tick must execute the pause guard, not reuse the failed task.
        await #expect(throws: TimerError.reviewRequired) { try await model.enqueueTimer(.checkpoint).value }
        #expect(!model.isBusy)
        await fixture.dispose()
    }
}

extension WorkspaceModelTests {
    @Test func correctionTimerEditFIFOAndAcceptedCancellation() async throws {
        let f = try await TimerFixture.make(), model = f.model
        let before = try #require(model.snapshot)
        let shown = try CorrectionPlanner.preview(.add(id: UUID(), taskID: f.first, startAt: 10, endAt: 20), in: before)
        let correction = model.enqueueCorrection(.apply(shown))
        correction.cancel()
        let start = model.enqueueTimer(.start(taskID: f.second))
        let changed = try await correction.value, running = try await start.value
        #expect(changed.revision == before.revision + 1 && running.revision == changed.revision + 1)
        #expect(running.entries.contains(shown.draft.entry) && running.activeTimer != nil)
        let renamed = try await model.submit(.renameTask(id: f.first, name: "Renamed"), expectedRevision: running.revision)
        #expect(renamed.entries == running.entries)
        #expect(model.canUndoCorrection)
        let undone = try await model.enqueueCorrection(.undo).value
        #expect(undone.activeTimer == running.activeTimer && !undone.entries.contains(shown.draft.entry))
        #expect(!model.canUndoCorrection)
        await f.dispose()
    }

    @Test func queuedRenameMakesPreviewStaleWithoutBlanketRevisionCheck() async throws {
        let f = try await TimerFixture.make(), model = f.model
        let before = try #require(model.snapshot)
        let shown = try CorrectionPlanner.preview(.add(id: UUID(), taskID: f.first, startAt: 10, endAt: 20), in: before)
        let rename = model.enqueueSubmit(.renameTask(id: f.first, name: "Changed"), expectedRevision: before.revision)
        let correction = model.enqueueCorrection(.apply(shown))
        _ = try await rename.value
        await #expect(throws: CorrectionError.stalePreview) { try await correction.value }
        #expect(model.snapshot?.entries.isEmpty == true && !model.canUndoCorrection)
        let fresh = try CorrectionPlanner.preview(shown.draft, in: #require(model.snapshot))
        _ = try await model.enqueueCorrection(.apply(fresh)).value
        #expect(model.canUndoCorrection)
        await f.dispose()
    }

    @Test func confirmedReceiptRollbackRetentionAndExplicitReopen() async throws {
        let f = try await TimerFixture.make(), model = f.model
        let before = try #require(model.snapshot)
        let shown = try CorrectionPlanner.preview(.add(id: UUID(), taskID: f.first, startAt: 10, endAt: 20), in: before)
        let barrier = TimerTestBarrier()
        model.configureCorrections { library, command, receipt, revision, instant in
            let committed = try await library.performCorrection(command, receipt: receipt, expectedRevision: revision, instant: instant)
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
        await f.dispose()
    }

    @Test func uncertainPublicationBlocksWithoutReceiptOrReplay() async throws {
        let f = try await TimerFixture.make(), model = f.model
        let before = try #require(model.snapshot)
        let shown = try CorrectionPlanner.preview(.add(id: UUID(), taskID: f.first, startAt: 10, endAt: 20), in: before)
        model.configureCorrections { library, command, receipt, revision, instant in
            _ = try await library.performCorrection(command, receipt: receipt, expectedRevision: revision, instant: instant)
            throw LibraryAccessError.publicationIndeterminate
        }
        await #expect(throws: LibraryAccessError.publicationIndeterminate) { try await model.enqueueCorrection(.apply(shown)).value }
        #expect(model.availability == .blocked && model.snapshot == before && !model.canUndoCorrection)
        await #expect(throws: LibraryAccessError.unavailable) { try await model.enqueueCorrection(.apply(shown)).value }
        try await model.open()
        #expect(model.snapshot?.revision == before.revision + 1 && model.snapshot?.entries == [shown.draft.entry])
        #expect(!model.canUndoCorrection)
        await f.dispose()
    }

    @Test func queuedGenerationMismatchAndLaterLatchArePreserved() async throws {
        let f = try await TimerFixture.make(), model = f.model
        let before = try #require(model.snapshot)
        let one = try CorrectionPlanner.preview(.add(id: UUID(), taskID: f.first, startAt: 10, endAt: 20), in: before)
        let two = try CorrectionPlanner.preview(.add(id: UUID(), taskID: f.second, startAt: 30, endAt: 40), in: before)
        let barrier = TimerTestBarrier()
        model.configureCorrections { library, command, receipt, revision, instant in
            let committed = try await library.performCorrection(command, receipt: receipt, expectedRevision: revision, instant: instant)
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
        await f.dispose()
    }

    @Test func correctionRejectsRestoredPausedAndPendingReview() async throws {
        let f = try await TimerFixture.make(), model = f.model
        let running = try await model.enqueueTimer(.start(taskID: f.first)).value
        let shown = try CorrectionPlanner.preview(.add(id: UUID(), taskID: f.second, startAt: 10, endAt: 20), in: running)
        f.clock.set(99)
        await #expect(throws: TimerError.clockRollback) { try await model.enqueueCorrection(.apply(shown)).value }
        f.clock.set(110)
        await #expect(throws: TimerError.reviewRequired) { try await model.enqueueCorrection(.apply(shown)).value }
        await model.close()
        try await model.open()
        await #expect(throws: TimerError.reviewRequired) { try await model.enqueueCorrection(.apply(shown)).value }
        #expect(model.snapshot == running && !model.canUndoCorrection)
        await f.dispose()
        let gate = TimerLifecycleGate(), fixture = CorrectionFixture()
        for wake: Int64? in [nil, 60] {
            let pending = PendingSleepInterval(id: UUID(), taskID: fixture.leaf, sleepAt: 50, wakeAt: wake)
            #expect(throws: TimerError.reviewRequired) {
                try gate.correctionSample(in: fixture.state(pending: [pending]), ownedEntryID: nil, paused: false, clock: { 100 })
            }
        }
    }
}

extension WorkspaceModelTests {
    @Test func reviewFIFOAcceptedCancellationAndReceiptPublication() async throws {
        let f = try await TimerFixture.make(), model = f.model
        _ = try await model.enqueueTimer(.start(taskID: f.first)).value
        f.clock.set(110)
        let generation = model.timerLifecycleGate.latchSleep()
        await model.enqueueSleepObservation(generation: generation).value
        let before = try #require(model.snapshot)
        let shown = try SleepPlanner.skip(#require(before.pendingSleepIntervals.first), in: before)
        let barrier = TimerTestBarrier()
        model.configureTimeReview { library, command, receipt, revision, instant in
            let committed = try await library.performTimeReview(command, receipt: receipt, expectedRevision: revision, instant: instant)
            await barrier.hold()
            return committed
        }
        let task = model.enqueueTimeReview(.skip(shown))
        task.cancel()
        await barrier.wait()
        #expect(model.snapshot == before && !model.canUndoTimeReview)
        let start = model.enqueueTimer(.start(taskID: f.second))
        await barrier.release()
        let saved = try await task.value, started = try await start.value
        #expect(saved.revision == before.revision + 1 && started.revision == saved.revision + 1)
        #expect(!model.canUndoTimeReview && !model.canUndoCorrection)
        // An unknown-pending Undo cannot coexist with the newly owned active row.
        await #expect(throws: SleepError.undoUnavailable) { try await model.enqueueTimeReview(.undo).value }
        #expect(model.snapshot == started)
        let stop = try await model.enqueueTimer(.stop(expectedEntryID: started.activeTimer?.entryID)).value
        #expect(model.canUndoTimeReview && stop.activeTimer == nil)
        _ = try await model.enqueueTimeReview(.undo).value
        #expect(!model.canUndoTimeReview && model.snapshot?.pendingSleepIntervals == before.pendingSleepIntervals)
        await f.dispose()
    }

    @Test func acceptedReviewCannotCrossGenerationAndOldPublicationDoesNotResetNewLatch() async throws {
        let f = try await TimerFixture.make(), model = f.model
        _ = try await model.enqueueTimer(.start(taskID: f.first)).value
        f.clock.set(110)
        let first = model.timerLifecycleGate.latchSleep()
        await model.enqueueSleepObservation(generation: first).value
        let sleeping = try #require(model.snapshot)
        let shown = try SleepPlanner.skip(#require(sleeping.pendingSleepIntervals.first), in: sleeping)
        let barrier = TimerTestBarrier()
        model.configureTimeReview { library, command, receipt, revision, instant in
            let committed = try await library.performTimeReview(command, receipt: receipt, expectedRevision: revision, instant: instant)
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
        await f.dispose()
    }

    @Test func sleepWakeFailuresNeverPublishPartialStateOrInventContinuation() async throws {
        for waking in [false, true] {
            for mode in 0..<3 {
                let f = try await TimerFixture.make(), model = f.model
                _ = try await model.enqueueTimer(.start(taskID: f.first)).value
                f.clock.set(110)
                let generation = model.timerLifecycleGate.latchSleep()
                if waking { await model.enqueueSleepObservation(generation: generation).value }
                let before = try #require(model.snapshot)
                model.configureSleepObservations { library, command, revision in
                    if mode == 0 { throw StorageError.injectedFailure }
                    if mode == 1 { throw StorageError.sqlite(5, "rejected") }
                    _ = try await library.performSleepObservation(command, expectedRevision: revision)
                    throw LibraryAccessError.publicationIndeterminate
                }
                if waking { await model.enqueueWakeObservation(generation: generation, observedAt: 120).value }
                else { await model.enqueueSleepObservation(generation: generation).value }
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
                await f.dispose()
            }
        }
    }

    @Test func reviewAndUndoFaultsRetainOnlyPublishedReceiptsAndNeverReplay() async throws {
        for undoing in [false, true] {
            for mode in 0..<3 {
                let f = try await TimerFixture.make(), model = f.model
                _ = try await model.enqueueTimer(.start(taskID: f.first)).value
                f.clock.set(110)
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
                    _ = try await library.performTimeReview(command, receipt: receipt, expectedRevision: revision, instant: instant)
                    throw LibraryAccessError.publicationIndeterminate
                }
                do { _ = try await model.enqueueTimeReview(command).value; Issue.record("fault succeeded") }
                catch { }
                #expect(model.snapshot == before)
                #expect(model.canUndoTimeReview == (undoing && mode < 2))
                if mode == 2 { #expect(model.availability == .blocked) }
                else if undoing {
                    model.configureTimeReview { library, command, receipt, revision, instant in
                        try await library.performTimeReview(command, receipt: receipt, expectedRevision: revision, instant: instant)
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
                await f.dispose()
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
        #expect(try model.projectReport(fixture.project, period: .allTime, calendar: calendar)
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
                model.configureTimer(clock: { fixture.clock.read() }, write: { _, _, _, _, _ in
                    throw StorageError.injectedFailure
                })
                await #expect(throws: StorageError.injectedFailure) {
                    try await model.enqueueTimer(.checkpoint).value
                }
            case 2:
                model.configureTimer(clock: { fixture.clock.read() }, write: { _, _, _, _, _ in
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
