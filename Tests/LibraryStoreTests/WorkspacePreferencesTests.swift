import Foundation
import Observation
import Testing

@testable import LibraryStore

private enum PreferenceTestError: Error, Equatable { case injected }

private func preferenceDirectory() -> URL {
    URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path, isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private actor PreferenceGate {
    private var entered = false
    private var released = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var resume: CheckedContinuation<Void, Never>?
    private(set) var events: [Int] = []

    func record(_ value: Int) { events.append(value) }
    func pause() async {
        entered = true
        arrival?.resume()
        arrival = nil
        if !released { await withCheckedContinuation { resume = $0 } }
    }
    func waitForArrival() async {
        if !entered { await withCheckedContinuation { arrival = $0 } }
    }
    func release() {
        released = true
        resume?.resume()
        resume = nil
    }
}

private final class PreferenceObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func changed() { lock.withLock { count += 1 } }
    var changes: Int { lock.withLock { count } }
}

@Suite @MainActor struct WorkspacePreferencesTests {
    @Test func defaultsEveryWeekdayAndInvalidInputPersist() async throws {
        let directory = preferenceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WorkspaceModel(directory: directory)
        #expect(model.firstWeekday == nil)
        await #expect(throws: LibraryAccessError.unavailable) { try await model.setFirstWeekday(3) }
        try await model.open()
        #expect(model.firstWeekday == 2)
        let before = model.snapshot
        for invalid in [0, 8, -1] {
            await #expect(throws: PreferenceError.invalidFirstWeekday(invalid)) {
                try await model.setFirstWeekday(invalid)
            }
            #expect(model.firstWeekday == 2)
            #expect(model.snapshot == before)
        }
        for day in 1...7 {
            try await model.setFirstWeekday(day)
            #expect(model.firstWeekday == day)
            #expect(model.snapshot == before)
            await model.close()
            #expect(model.firstWeekday == nil)
            try await model.open()
            #expect(model.firstWeekday == day)
            #expect(model.snapshot == before)
        }
        await model.close()
    }

    @Test func openingAndReadFailuresNeverPublishFallbackAndReleaseLease() async throws {
        for invalid in [false, true] {
            let directory = preferenceDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let gate = PreferenceGate()
            var operations = WorkspaceOperations()
            operations.settings = { _ in
                await gate.pause()
                if invalid { return LibrarySettings(firstWeekday: 8) }
                throw PreferenceTestError.injected
            }
            let model = WorkspaceModel(directory: directory, operations: operations)
            let opening = model.enqueueOpen()
            await gate.waitForArrival()
            #expect(model.availability == .opening)
            #expect(model.firstWeekday == nil)
            await #expect(throws: LibraryAccessError.unavailable) { try await model.setFirstWeekday(3) }
            await gate.release()
            do {
                try await opening.value
                Issue.record("invalid settings accepted")
            } catch {}
            #expect(model.availability == .blocked)
            #expect(model.firstWeekday == nil)
            #expect(model.snapshot == nil)
            #expect(model.issue != nil)
            #expect(!model.isBusy)
            let next = try await Library.open(at: directory)
            #expect(try await next.settings().firstWeekday == 2)
            await next.close()
            await model.close()
        }
    }

    @Test func malformedStoredSettingsAreNotOverwritten() async throws {
        let directory = preferenceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.plist")
        let bad = try PropertyListSerialization.data(
            fromPropertyList: ["version": 1, "firstWeekday": 8], format: .binary, options: 0)
        try bad.write(to: url)
        let model = WorkspaceModel(directory: directory)
        do {
            try await model.open()
            Issue.record("invalid stored weekday accepted")
        } catch is LibraryAccessError {}
        #expect(model.firstWeekday == nil)
        #expect(model.availability == .blocked)
        #expect(try Data(contentsOf: url) == bad)
        try FileManager.default.removeItem(at: url)
        try await model.open()
        #expect(model.firstWeekday == 2)
        await model.close()
    }

    @Test func confirmedObservationFIFOCallerOutcomesCancellationAndClose() async throws {
        let directory = preferenceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = PreferenceGate()
        var operations = WorkspaceOperations()
        operations.setFirstWeekday = { library, day in
            await gate.record(day)
            if day == 3 { await gate.pause() }
            if day == 4 { throw PreferenceTestError.injected }
            return try await library.setFirstWeekday(day)
        }
        operations.perform = { library, command, revision in
            await gate.record(0)
            return try await library.perform(command, expectedRevision: revision)
        }
        let model = WorkspaceModel(directory: directory, operations: operations)
        try await model.open()
        let shared = model
        let observation = PreferenceObservation()
        withObservationTracking {
            _ = shared.firstWeekday
        } onChange: {
            observation.changed()
        }
        let first = model.enqueueFirstWeekday(3)
        await gate.waitForArrival()
        first.cancel()
        #expect(model.firstWeekday == 2)
        #expect(observation.changes == 0)
        #expect(model.isBusy)
        let command = model.enqueueSubmit(
            .createProject(id: UUID(), name: "Client", rate: 12, currency: "EUR"), expectedRevision: 0)
        let failed = model.enqueueFirstWeekday(4)
        let last = model.enqueueFirstWeekday(5)
        let closing = model.enqueueClose()
        await #expect(throws: LibraryAccessError.unavailable) { try await model.setFirstWeekday(6) }
        #expect(model.availability == .closing)
        await gate.release()
        try await first.value
        #expect(try await command.value.projects.count == 1)
        await #expect(throws: PreferenceTestError.injected) { try await failed.value }
        try await last.value
        await closing.value
        #expect(await gate.events == [3, 0, 4, 5])
        #expect(observation.changes == 1)
        #expect(shared.firstWeekday == nil)
        #expect(!model.isBusy)
        #expect(model.availability == .closed)
        try await model.open()
        #expect(shared.firstWeekday == 5)
        #expect(model.snapshot?.projects.count == 1)
        await model.close()
    }

    @Test func reviewRequiredPreferencePreservesAllDomainAndTimeState() async throws {
        let directory = preferenceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = UUID()
        let task = UUID()
        let entry = UUID()
        let before = LibrarySnapshot(
            schemaVersion: 2, revision: 12,
            projects: [Project(id: project, name: "Client", hourlyRate: 25, currencyCode: "EUR")],
            tasks: [
                TaskRecord(id: task, projectID: project, name: "Work", budgetMinutes: 100, lastWarnedThreshold: .eighty)
            ],
            entries: [TimeEntry(id: entry, taskID: task, startAt: 10, endAt: nil)],
            activeTimer: ActiveTimer(entryID: entry, checkpointAt: 20),
            pendingSleepIntervals: [PendingSleepInterval(id: UUID(), taskID: task, sleepAt: 1, wakeAt: 5)])
        var operations = WorkspaceOperations()
        operations.snapshot = { _ in before }
        let model = WorkspaceModel(directory: directory, operations: operations)
        try await model.open()
        #expect(model.availability == .reviewRequired)
        try await model.setFirstWeekday(7)
        #expect(model.firstWeekday == 7)
        #expect(model.availability == .reviewRequired)
        #expect(model.snapshot == before)
        await model.close()
    }

    @Test func durableFailuresRetainSelectionAndExplicitReopenDoesNotReplay() async throws {
        for uncertain in [false, true] {
            let directory = preferenceDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let calls = PreferenceGate()
            let hooks = RecoveryHooks(failureInjector: { point in
                if point == (uncertain ? .settingsRenamed : .settingsWritten) {
                    throw PreferenceTestError.injected
                }
            })
            var operations = WorkspaceOperations()
            operations.open = { try await Library.open(at: $0, hooks: hooks) }
            operations.setFirstWeekday = { library, day in
                await calls.record(day)
                return try await library.setFirstWeekday(day)
            }
            let model = WorkspaceModel(directory: directory, operations: operations)
            try await model.open()
            let before = model.snapshot
            let shared = model
            let observation = PreferenceObservation()
            withObservationTracking {
                _ = shared.firstWeekday
            } onChange: {
                observation.changed()
            }
            do {
                try await model.setFirstWeekday(7)
                Issue.record("fault did not fail save")
            } catch {
                if uncertain {
                    #expect((error as? LibraryAccessError) == .publicationIndeterminate)
                } else {
                    #expect((error as? PreferenceTestError) == .injected)
                }
            }
            #expect(model.firstWeekday == 2)
            #expect(observation.changes == 0)
            #expect(model.snapshot == before)
            if uncertain {
                #expect(model.availability == .blocked)
                #expect(model.issue == .uncertainSave)
                await #expect(throws: LibraryAccessError.unavailable) { try await model.setFirstWeekday(3) }
                try await model.open()
                #expect(model.firstWeekday == 7)
            } else {
                #expect(model.availability == .ready)
                #expect(model.issue != nil)
                await model.close()
                try await model.open()
                #expect(model.firstWeekday == 2)
            }
            #expect(await calls.events == [7])
            #expect(model.snapshot == before)
            await model.close()
        }
    }
}
