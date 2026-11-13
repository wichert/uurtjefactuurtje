import AppKit
import Foundation
import SwiftUI
import Testing
import UserNotifications

@testable import LibraryStore
@testable import UurtjeFactuurtje

actor NativeSubmissionGate {
    private var entered = false
    private var released = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        arrival?.resume()
        arrival = nil
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func waitForArrival() async {
        if !entered { await withCheckedContinuation { arrival = $0 } }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

final class NativeQuitWriteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite @MainActor struct NativeHostTests {
    @Test func notificationsConsentDedupAndDefensiveResponses() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let id = try await task(track, project: projectID)
            var prompts = 0
            var delivered: [UNNotificationRequest] = []
            var revealed: [UUID] = []
            let notifications = BudgetNotifications(
                path: { _ in "Project / Parent / Task" }, reveal: { revealed.append($0) },
                authorizationStatus: { .notDetermined },
                requestAuthorization: {
                    prompts += 1
                    return true
                },
                deliver: { delivered.append($0) })
            let batch = BudgetWarningBatch(id: UUID(), warnings: [BudgetWarning(taskID: id, threshold: .eighty)])
            let baseline = try #require(track.workspace.snapshot)
            notifications.consume(snapshot: baseline, batches: [batch])
            await notifications.waitForPendingDelivery()
            #expect(prompts == 0)
            #expect(delivered.isEmpty)
            let enabled = LibrarySnapshot(
                schemaVersion: 2, revision: baseline.revision + 1,
                projects: baseline.projects,
                tasks: [TaskRecord(id: id, projectID: projectID, name: "Task", budgetMinutes: 100)],
                entries: [], activeTimer: nil, pendingSleepIntervals: [])
            let fresh = BudgetWarningBatch(id: UUID(), warnings: batch.warnings)
            notifications.consume(snapshot: enabled, batches: [batch, fresh])
            notifications.consume(snapshot: enabled, batches: [batch, fresh])
            await notifications.waitForPendingDelivery()
            #expect(prompts == 1)
            #expect(delivered.count == 1)
            #expect(delivered[0].content.sound != nil)
            #expect(delivered.first?.content.body.contains("Project / Parent / Task") == true)
            #expect(BudgetNotifications.taskIDs(in: delivered[0].content.userInfo) == [id])
            for malformed: [AnyHashable: Any] in [
                [:], ["taskIDs": "bad"], ["taskIDs": ["bad"]],
                ["taskIDs": [id.uuidString.lowercased(), id.uuidString.lowercased()]], ["taskIDs": []]
            ] {
                #expect(BudgetNotifications.taskIDs(in: malformed) == nil)
            }
            notifications.consume(snapshot: nil, batches: [])
            notifications.consume(snapshot: enabled, batches: [fresh])
            await notifications.waitForPendingDelivery()
            #expect(delivered.count == 1)
            #expect(revealed.isEmpty)
            var completions = 0
            notifications.handleResponse(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                userInfo: ["taskIDs": [id.uuidString.lowercased()]], completion: { completions += 1 })
            notifications.handleResponse(
                actionIdentifier: UNNotificationDismissActionIdentifier,
                userInfo: ["taskIDs": [id.uuidString.lowercased()]], completion: { completions += 1 })
            notifications.handleResponse(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                userInfo: ["taskIDs": ["invalid"]], completion: { completions += 1 })
            #expect(completions == 3)
            // Queue behind the response'statement MainActor hop, without timer notification daemon.
            await Task { @MainActor in }.value
            #expect(revealed == [id])

            var deniedPrompts = 0
            var deniedDeliveries = 0
            let denied = BudgetNotifications(
                path: { _ in "Task" }, reveal: { _ in },
                authorizationStatus: { .notDetermined },
                requestAuthorization: {
                    deniedPrompts += 1
                    return false
                },
                deliver: { _ in deniedDeliveries += 1 })
            denied.consume(snapshot: baseline, batches: [])
            denied.consume(snapshot: enabled, batches: [fresh])
            denied.consume(snapshot: enabled, batches: [fresh])
            await denied.waitForPendingDelivery()
            #expect(deniedPrompts == 1)
            #expect(deniedDeliveries == 0)
        }
    }

    @Test func savedPendingReviewDefersUnbilledAndStopsOwnedTimerOnce() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            let clock = NativeClock()
            track.workspace.configureTimer(clock: { clock.read() })
            let projectID = try await project(track)
            let id = try await task(track, project: projectID)
            host.submitTimer(.start(taskID: id))
            await host.drain()
            let lifecycle = Lifecycle(host: host)
            clock.set(110)
            lifecycle.willSleep()
            await host.drain()
            lifecycle.didWake(at: Date(timeIntervalSince1970: 120))
            await host.drain()
            let before = try #require(track.workspace.snapshot)
            #expect(before.pendingSleepIntervals.count == 1)
            let writes = NativeQuitWriteProbe()
            let expectedStop = host.track.ownedStop
            var closes = 0
            var replies = 0
            track.workspace.configureTimer(
                clock: { 130 },
                write: { library, command, revision, instant, entry in
                    writes.record()
                    #expect(command == expectedStop)
                    return try await library.performTimer(
                        command, expectedRevision: revision, instant: instant,
                        newEntryID: entry)
                })
            lifecycle.confirmQuit = { true }
            lifecycle.close = { model in
                closes += 1
                #expect(model.snapshot?.activeTimer == nil)
                #expect(model.snapshot?.pendingSleepIntervals == before.pendingSleepIntervals)
                #expect(model.snapshot?.entries.contains { $0.startAt == 110 && $0.endAt == 120 } == false)
                await model.close()
            }
            await withCheckedContinuation { done in
                lifecycle.reply = { succeeded in
                    #expect(succeeded)
                    replies += 1
                    done.resume()
                }
                lifecycle.requestQuit()
                lifecycle.requestQuit()
            }
            #expect(writes.count == 1 && closes == 1 && replies == 1)
            lifecycle.requestQuit()
            #expect(closes == 1 && replies == 1)
            try await track.workspace.open()
            #expect(track.workspace.snapshot?.pendingSleepIntervals == before.pendingSleepIntervals)
            #expect(track.workspace.snapshot?.activeTimer == nil)
            #expect(lifecycle.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared) == false)
            host.invalidate()
        }
    }

    @Test func sleepingUnknownEndClosesWithoutInferringBounds() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            let clock = NativeClock()
            track.workspace.configureTimer(clock: { clock.read() })
            let projectID = try await project(track)
            let id = try await task(track, project: projectID)
            host.submitTimer(.start(taskID: id))
            await host.drain()
            let lifecycle = Lifecycle(host: host)
            clock.set(110)
            lifecycle.willSleep()
            await host.drain()
            let before = try #require(track.workspace.snapshot)
            #expect(before.pendingSleepIntervals.first?.wakeAt == nil)
            let writes = NativeQuitWriteProbe()
            track.workspace.configureTimer(
                clock: { 999 },
                write: { _, _, _, _, _ in
                    writes.record()
                    throw StorageError.injectedFailure
                })
            lifecycle.confirmQuit = { true }
            lifecycle.close = { model in
                #expect(model.snapshot == before)
                await model.close()
            }
            await withCheckedContinuation { done in
                lifecycle.reply = { succeeded in
                    #expect(succeeded)
                    done.resume()
                }
                lifecycle.requestQuit()
            }
            #expect(writes.count == 0)
            try await track.workspace.open()
            #expect(track.workspace.snapshot == before)
            host.invalidate()
        }
    }

    @Test func unavailableQuitDoesNotReopenOrMutate() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            let projectID = try await project(track)
            let id = try await task(track, project: projectID)
            host.submitTimer(.start(taskID: id))
            await host.drain()
            let before = try #require(track.workspace.snapshot)
            await track.workspace.close()
            let writes = NativeQuitWriteProbe()
            var closes = 0
            track.workspace.configureTimer(
                clock: { 999 },
                write: { _, _, _, _, _ in
                    writes.record()
                    throw StorageError.injectedFailure
                })
            let lifecycle = Lifecycle(host: host)
            lifecycle.confirmQuit = { true }
            lifecycle.close = { model in
                closes += 1
                await model.close()
            }
            await withCheckedContinuation { done in
                lifecycle.reply = { succeeded in
                    #expect(succeeded)
                    done.resume()
                }
                lifecycle.requestQuit()
            }
            #expect(writes.count == 0 && closes == 1)
            try await track.workspace.open()  // Test inspection, never timer Quit recovery action.
            #expect(track.workspace.snapshot == before)
            host.invalidate()
        }
    }

    @Test func uncertainQuitRetainsUncertaintyAndNeverResubmits() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            let clock = NativeClock()
            track.workspace.configureTimer(clock: { clock.read() })
            let projectID = try await project(track)
            let id = try await task(track, project: projectID)
            host.submitTimer(.start(taskID: id))
            await host.drain()
            let before = try #require(track.workspace.snapshot)
            let writes = NativeQuitWriteProbe()
            var closes = 0
            track.workspace.configureTimer(
                clock: { 110 },
                write: { _, _, _, _, _ in
                    writes.record()
                    throw LibraryAccessError.publicationIndeterminate
                })
            host.submitTimer(.checkpoint)
            await host.drain()
            #expect(host.hasUncertainPublication)
            #expect(track.workspace.snapshot == before)
            // Phase 7 tests separately cover timer later issue replacing uncertainSave.
            let lifecycle = Lifecycle(host: host)
            lifecycle.confirmQuit = {
                #expect(host.hasUncertainPublication)
                return true
            }
            lifecycle.close = { model in
                closes += 1
                #expect(model.snapshot == before && model.publicationUncertain)
                await model.close()
            }
            await withCheckedContinuation { done in
                lifecycle.reply = { succeeded in
                    #expect(succeeded)
                    done.resume()
                }
                lifecycle.requestQuit()
            }
            #expect(writes.count == 1 && closes == 1)
            #expect(host.hasUncertainPublication)  // Close is not confirmed inspection/reopen.
            host.invalidate()
        }
    }

}
