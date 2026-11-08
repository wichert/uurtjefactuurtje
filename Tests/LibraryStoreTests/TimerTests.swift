import Foundation
import Testing
@testable import LibraryStore

final class TimerTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    private var count = 0
    init(_ value: Int64 = 100) { self.value = value }
    func set(_ value: Int64) { lock.lock(); defer { lock.unlock() }; self.value = value }
    func read() -> Int64 { lock.lock(); defer { lock.unlock() }; count += 1; return value }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
}

actor TimerTestBarrier {
    private var entered = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        arrivals.forEach { $0.resume() }; arrivals.removeAll()
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func wait() async { if !entered { await withCheckedContinuation { arrivals.append($0) } } }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}

@MainActor struct TimerFixture {
    let directory: URL
    let model: WorkspaceModel
    let clock: TimerTestClock
    let project: UUID
    let first: UUID
    let second: UUID

    static func make() async throws -> TimerFixture {
        let directory = URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = WorkspaceModel(directory: directory)
        let clock = TimerTestClock()
        model.configureTimer(clock: { clock.read() })
        try await model.open()
        let project = UUID(), first = UUID(), second = UUID()
        _ = try await model.submit(.createProject(id: project, name: "Client", rate: 1, currency: "EUR"), expectedRevision: 0)
        _ = try await model.submit(.createTask(id: first, projectID: project, parentID: nil, name: "First"), expectedRevision: 1)
        _ = try await model.submit(.createTask(id: second, projectID: project, parentID: nil, name: "Second"), expectedRevision: 2)
        return TimerFixture(directory: directory, model: model, clock: clock, project: project, first: first, second: second)
    }
    func dispose() async {
        await model.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite @MainActor struct TimerTests {
    @Test func atomicSwitchNoOpsZeroIntervalsAndReopen() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let started = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        let firstID = try #require(started.activeTimer?.entryID)
        #expect(started.activeTimer?.checkpointAt == 100)
        #expect(started.entries.first?.startAt == 100)
        #expect(try await model.enqueueTimer(.start(taskID: fixture.first)).value == started)
        #expect(try await model.enqueueTimer(.checkpoint).value == started)
        let sameSecond = try await model.enqueueTimer(.start(taskID: fixture.second)).value
        #expect(sameSecond.entries.count == 1 && sameSecond.entries[0].taskID == fixture.second)
        #expect(sameSecond.entries[0].id != firstID)
        fixture.clock.set(110)
        let switched = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        #expect(switched.entries.first(where: { $0.taskID == fixture.second })?.endAt == 110)
        #expect(switched.entries.first(where: { $0.id == switched.activeTimer?.entryID })?.startAt == 110)
        let stopped = try await model.enqueueTimer(.stop(expectedEntryID: switched.activeTimer?.entryID)).value
        #expect(stopped.activeTimer == nil && stopped.entries.count == 1)
        #expect(try await model.enqueueTimer(.stop(expectedEntryID: nil)).value == stopped)
        await model.close()
        try await model.open()
        #expect(model.snapshot == stopped && model.timerStatus == .idle)
        await fixture.dispose()
    }

    @Test func checkpointRollbackSafeStopAndFutureCheckpoint() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        _ = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        fixture.clock.set(120)
        let saved = try await model.enqueueTimer(.checkpoint).value
        let id = try #require(saved.activeTimer?.entryID)
        fixture.clock.set(119)
        await #expect(throws: TimerError.clockRollback) { try await model.enqueueTimer(.checkpoint).value }
        #expect(model.snapshot == saved && model.timerStatus == .paused(entryID: id))
        await #expect(throws: TimerError.clockRollback) {
            try await model.enqueueTimer(.stopAtCheckpoint(expectedEntryID: id)).value
        }
        fixture.clock.set(200)
        await #expect(throws: TimerError.reviewRequired) { try await model.enqueueTimer(.checkpoint).value }
        let stopped = try await model.enqueueTimer(.stopAtCheckpoint(expectedEntryID: id)).value
        #expect(stopped.entries.first?.endAt == 120 && stopped.activeTimer == nil)
        await fixture.dispose()
    }

    @Test func targetAndObservedIdentityGuards() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let started = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        await #expect(throws: TimerError.missingTask) { try await model.enqueueTimer(.start(taskID: UUID())).value }
        await #expect(throws: TimerError.activeEntryChanged) { try await model.enqueueTimer(.stop(expectedEntryID: nil)).value }
        await #expect(throws: TimerError.activeEntryChanged) { try await model.enqueueTimer(.stop(expectedEntryID: UUID())).value }
        #expect(model.snapshot == started)
        let parent = UUID()
        var current = try await model.submit(.createTask(id: parent, projectID: fixture.project, parentID: nil, name: "Parent"), expectedRevision: started.revision)
        current = try await model.submit(.createTask(id: UUID(), projectID: fixture.project, parentID: parent, name: "Child"), expectedRevision: current.revision)
        await #expect(throws: TimerError.notALeaf) { try await model.enqueueTimer(.start(taskID: parent)).value }
        let otherProject = UUID(), archivedTask = UUID()
        current = try await model.submit(.createProject(id: otherProject, name: "Archive", rate: 0, currency: "USD"), expectedRevision: current.revision)
        current = try await model.submit(.createTask(id: archivedTask, projectID: otherProject, parentID: nil, name: "Old"), expectedRevision: current.revision)
        current = try await model.submit(.setArchived(id: otherProject, archived: true), expectedRevision: current.revision)
        await #expect(throws: TimerError.archivedProject) { try await model.enqueueTimer(.start(taskID: archivedTask)).value }
        #expect(model.snapshot == current)
        fixture.clock.set(110)
        let switched = try await model.enqueueTimer(.start(taskID: fixture.second)).value
        await #expect(throws: TimerError.activeEntryChanged) {
            try await model.enqueueTimer(.stop(expectedEntryID: started.activeTimer?.entryID)).value
        }
        #expect(model.snapshot == switched)
        _ = try await model.enqueueTimer(.stop(expectedEntryID: switched.activeTimer?.entryID)).value
        fixture.clock.set(105)
        await #expect(throws: TimerError.clockRollback) { try await model.enqueueTimer(.start(taskID: fixture.first)).value }
        await fixture.dispose()
    }

    @Test func restoredActiveHasNoProcessProvenance() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let saved = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        let id = try #require(saved.activeTimer?.entryID)
        await model.close()
        try await model.open()
        #expect(model.availability == .reviewRequired && model.timerStatus == .reviewRequired)
        for command: TimerCommand in [.start(taskID: fixture.second), .stop(expectedEntryID: id), .checkpoint, .stopAtCheckpoint(expectedEntryID: id)] {
            await #expect(throws: TimerError.reviewRequired) { try await model.enqueueTimer(command).value }
        }
        #expect(model.snapshot == saved)
        await fixture.dispose()
    }

    @Test func knownFailurePausesAndLostAcknowledgementBlocks() async throws {
        let fixture = try await TimerFixture.make()
        let model = fixture.model
        let saved = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        let id = try #require(saved.activeTimer?.entryID)
        fixture.clock.set(120)
        model.configureTimer(clock: { fixture.clock.read() }, write: { _, _, _, _, _ in throw StorageError.injectedFailure })
        await #expect(throws: StorageError.injectedFailure) { try await model.enqueueTimer(.start(taskID: fixture.second)).value }
        #expect(model.snapshot == saved && model.timerStatus == .paused(entryID: id))
        model.configureTimer(clock: { fixture.clock.read() }, write: { library, command, revision, instant, newID in
            try await library.performTimer(command, expectedRevision: revision, instant: instant, newEntryID: newID)
        })
        let stopped = try await model.enqueueTimer(.stopAtCheckpoint(expectedEntryID: id)).value
        #expect(stopped.entries.isEmpty)
        _ = try await model.enqueueTimer(.start(taskID: fixture.first)).value
        let confirmed = model.snapshot
        fixture.clock.set(130)
        model.configureTimer(clock: { fixture.clock.read() }, write: { library, command, revision, instant, newID in
            _ = try await library.performTimer(command, expectedRevision: revision, instant: instant, newEntryID: newID)
            throw LibraryAccessError.publicationIndeterminate
        })
        await #expect(throws: LibraryAccessError.publicationIndeterminate) { try await model.enqueueTimer(.start(taskID: fixture.second)).value }
        #expect(model.snapshot == confirmed && model.availability == .blocked && model.issue == .uncertainSave)
        await #expect(throws: LibraryAccessError.unavailable) { try await model.enqueueTimer(.checkpoint).value }
        try await model.open()
        #expect(model.snapshot?.entries.last(where: { $0.endAt == nil })?.taskID == fixture.second)
        #expect(model.timerStatus == .reviewRequired)
        await fixture.dispose()
    }

    @Test func gateSamplesAndResetsOnlyCurrentGeneration() throws {
        let gate = TimerLifecycleGate()
        let clock = TimerTestClock()
        #expect(try gate.sample(clock: { clock.read() }).instant == 100)
        let first = gate.latchSleep()
        let before = clock.reads
        #expect(throws: TimerError.reviewRequired) { try gate.sample(clock: { clock.read() }) }
        #expect(clock.reads == before)
        let second = gate.latchSleep()
        #expect(second > first && !gate.reset(generation: first))
        #expect(gate.state().sleeping)
        #expect(gate.reset(generation: second))
        #expect(!gate.state().sleeping)
    }
}
