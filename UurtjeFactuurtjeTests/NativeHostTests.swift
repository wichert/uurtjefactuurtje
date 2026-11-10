import AppKit
import SwiftUI
import Foundation
import Testing
import UserNotifications
@testable import LibraryStore
@testable import UurtjeFactuurtje

private actor NativeSubmissionGate {
    private var entered = false
    private var released = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true; arrival?.resume(); arrival = nil
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func waitForArrival() async {
        if !entered { await withCheckedContinuation { arrival = $0 } }
    }
    func release() {
        released = true; continuation?.resume(); continuation = nil
    }
}

private final class NativeQuitWriteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite @MainActor struct NativeHostTests {
    @Test func soleOwnerPendingRoutesAndDrafts() async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace)
            #expect(host.track.workspace === host.workspace)
            #expect(host.workspace === t.workspace)
            let p = try await project(t), root = try await task(t, project: p, name: "Parent")
            let leaf = try await task(t, project: p, parent: root, name: "Leaf")
            var opens = 0, settings = 0
            host.revealNotificationTask(leaf); host.openReports(); host.openSettings()
            #expect(opens == 0)
            host.installSceneActions(workspace: { opens += 1 }, settings: { settings += 1 })
            #expect(opens == 2); #expect(settings == 1)
            #expect(host.track.destination == .reports); #expect(host.track.selectedTaskID == leaf)
            host.newTask(); let token = host.track.routeToken
            host.newProject(); host.addTime(); host.openReview(); host.revealNotificationTask(leaf)
            #expect(host.track.routeToken == token); #expect(host.track.sheet != nil)
            #expect(host.track.feedback != nil)
            #expect(WorkspaceMenu.matchingTasks(host.track, query: "Parent") == [leaf])
            #expect(!WorkspaceMenu.recentTasks(host.track).contains(root))
            host.track.cancelSheet()
            host.submitTimer(.start(taskID: leaf)); await host.drain()
            #expect(WorkspaceMenu.stopTitle(host.track) == "Stop Project / Parent / Leaf")
            #expect(WorkspaceMenu.recentTasks(host.track).isEmpty)
            host.submitTimer(.stop(expectedEntryID: t.workspace.snapshot?.activeTimer?.entryID)); await host.drain()
            #expect(WorkspaceMenu.recentTasks(host.track) == [leaf])

            let clock = NativeClock()
            // Sibling temp directory, not a subdirectory of the open library: the store
            // treats unknown artifacts inside its directory as unsafe on reopen.
            let recentDirectory = fixtureTemporaryDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: recentDirectory) }
            let suite = "MenuRecentTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = WorkspaceModel(directory: recentDirectory)
            model.configureTimer(clock: { clock.read() })
            let recentTrack = TrackPresentation(workspace: model, defaults: defaults)
            try await model.open()
            let projectID = try await project(recentTrack)
            let older = try await task(recentTrack, project: projectID, name: "Older")
            let newer = try await task(recentTrack, project: projectID, name: "Newer")
            let parent = try await task(recentTrack, project: projectID, name: "Parent")
            let child = try await task(recentTrack, project: projectID, parent: parent, name: "Child")
            for id in [older, newer, child] {
                _ = try await model.enqueueTimer(.start(taskID: id)).value
                clock.set(clock.read() + 1)
                _ = try await model.enqueueTimer(.stop(expectedEntryID: model.snapshot?.activeTimer?.entryID)).value
            }
            #expect(WorkspaceMenu.recentTasks(recentTrack) == [child, newer])
            #expect(WorkspaceMenu.recentTasks(recentTrack, limit: 3) == [child, newer, older])
            #expect(!WorkspaceMenu.recentTasks(recentTrack, limit: 3).contains(parent))
            #expect(WorkspaceMenu.matchingTasks(recentTrack, query: "Project / Parent / Child") == [child])
            #expect(WorkspaceMenu.matchingTasks(recentTrack, query: "Parent") == [child])
            #expect(WorkspaceMenu.matchingTasks(recentTrack, query: "").isEmpty)
            await model.close()
            await t.workspace.close()
            host.revealNotificationTask(leaf)
            host.reopen(); await host.drain()
            #expect(host.track.selectedTaskID == leaf)
            host.revealNotificationTask(UUID()); #expect(host.track.failure?.contains("no longer exists") == true)
            host.invalidate()
        }
    }

    @Test(arguments: [false, true])
    func reviewRouteSurvivesSceneActionReinstallation(afterSleep: Bool) async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace)
            defer { host.invalidate() }
            if afterSleep {
                let clock = NativeClock(), lifecycle = Lifecycle(host: host)
                t.workspace.configureTimer(clock: { clock.read() })
                let p = try await project(t), id = try await task(t, project: p)
                host.submitTimer(.start(taskID: id)); await host.drain()
                clock.set(110); lifecycle.willSleep(); await host.drain()
                lifecycle.didWake(at: Date(timeIntervalSince1970: 120)); await host.drain()
                #expect(t.workspace.snapshot?.pendingSleepIntervals.count == 1)
            }
            let before = t.workspace.snapshot
            var opens = 0
            host.installSceneActions(workspace: {
                opens += 1
                // Opening a window can synchronously re-evaluate NativeCommands.body.
                host.installSceneActions(workspace: { opens += 1 }, settings: {})
            }, settings: {})
            host.openReview()
            #expect(opens == 1)
            #expect(host.track.destination == .track)
            guard case .timeReview = host.track.sheet else { Issue.record("Missing time review"); return }
            #expect(host.track.feedback == nil)
            #expect(t.workspace.snapshot == before)
            host.track.cancelSheet()
            host.openReports()
            #expect(opens == 2 && host.track.destination == .reports)
        }
    }

    @Test func reentrantSceneCallbacksPreserveRouteOrder() async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace)
            defer { host.invalidate() }
            var events: [String] = []
            host.installSceneActions(workspace: {
                events.append("workspace")
                if events.count == 1 {
                    host.openSettings()
                    host.openReports()
                }
            }, settings: {
                events.append("settings")
                // The initial route must finish before the settings callback runs.
                #expect(host.track.sheet != nil)
                host.openTrack()
            })
            host.openReview()
            #expect(events == ["workspace", "settings", "workspace", "workspace"])
            #expect(host.track.destination == .track)
            #expect(host.track.feedback == nil)
        }
    }

    @Test func schedulerAndSleepWakeTimestamp() async throws {
        #expect(Lifecycle.checkpointInterval == 15)
        #expect(Lifecycle.budgetInterval == 1)
        #expect(MenuBarController.displayInterval == 1)
        #expect(Lifecycle.wholeSecond(Date(timeIntervalSince1970: 123.99)) == 123)
        #expect(Lifecycle.wholeSecond(Date(timeIntervalSince1970: -.infinity)) == nil)
        let timer = Lifecycle.scheduler(every: 15) {}
        #expect(timer.timeInterval == 15); timer.invalidate()
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace)
            let lifecycle = Lifecycle(host: host)
            let clock = NativeClock(); t.workspace.configureTimer(clock: { clock.read() })
            let p = try await project(t), id = try await task(t, project: p)
            host.submitTimer(.start(taskID: id)); await host.drain()
            clock.set(110); lifecycle.willSleep()
            #expect(lifecycle.sleeping)
            #expect(t.workspace.timerStatus != .running(entryID: t.workspace.snapshot!.activeTimer!.entryID))
            await lifecycle.host.drain()
            #expect(t.workspace.snapshot?.pendingSleepIntervals.first?.sleepAt == 110)
            lifecycle.didWake(at: Date(timeIntervalSince1970: 120.99))
            await lifecycle.host.drain()
            #expect(t.workspace.snapshot?.pendingSleepIntervals.first?.wakeAt == 120)
            #expect(!lifecycle.sleeping)
            host.invalidate(); lifecycle.host.invalidate()
        }
    }

    @Test func quitDrainsStopsClosesAndRepliesOnce() async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace), clock = NativeClock()
            t.workspace.configureTimer(clock: { clock.read() })
            let p = try await project(t), id = try await task(t, project: p)
            let lifecycle = Lifecycle(host: host)
            var events: [String] = []
            lifecycle.confirmQuit = { events.append("confirm"); clock.set(110); return true }
            lifecycle.close = { model in
                #expect(model.snapshot?.activeTimer == nil)
                #expect(model.snapshot?.entries.last?.taskID == id)
                events.append("close"); await model.close()
            }
            await withCheckedContinuation { done in
                lifecycle.reply = { permitted in
                    #expect(permitted); events.append("reply"); done.resume()
                }
                host.submitTimer(.start(taskID: id)) // Accepted FIFO work precedes quit.
                lifecycle.requestQuit()
                #expect(!host.acceptingMutations)
                host.submitTimer(.start(taskID: UUID()))
                lifecycle.checkpointTick(); lifecycle.budgetTick()
                lifecycle.requestQuit()
            }
            #expect(events == ["confirm", "close", "reply"])
            #expect(t.workspace.availability == .closed)
            host.invalidate()
        }
    }

    @Test func quitRejectsDirectCallbacksWhileAcceptedWorkDrains() async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace)
            let p = try await project(t), id = try await task(t, project: p)
            let gate = NativeSubmissionGate()
            t.workspace.configureTimer(clock: { 100 }, write: { library, command, revision, instant, entry in
                await gate.pause()
                return try await library.performTimer(command, expectedRevision: revision, instant: instant, newEntryID: entry)
            })
            host.track.editProject(p)
            let token = host.track.routeToken
            #expect(host.track.begin(token))
            let before = try #require(t.workspace.snapshot)
            host.submitTimer(.start(taskID: id))
            await gate.waitForArrival()
            let setting = try #require(host.submitFirstWeekday(4))
            let editor = t.workspace.enqueueSubmit(.renameTask(id: id, name: "Accepted"), expectedRevision: before.revision + 1)
            host.retain(Task { @MainActor in
                do { _ = try await editor.value; host.track.complete(token) }
                catch { host.track.complete(token, error: error); Issue.record("Accepted editor failed: \(error)") }
            })
            let lifecycle = Lifecycle(host: host)
            lifecycle.confirmQuit = { false }
            await withCheckedContinuation { done in
                lifecycle.reply = { ok in #expect(!ok); done.resume() }
                lifecycle.requestQuit()
                #expect(!host.track.begin(token))
                host.track.timer(.stop(expectedEntryID: nil))
                host.track.undoMigration(receiptID: UUID())
                host.track.undoCorrection()
                host.track.undoTimeReview()
                #expect(host.submitFirstWeekday(5) == nil)
                #expect(host.track.acceptedWork)
                Task { await gate.release() }
            }
            try await setting.value
            await host.drain()
            #expect(t.workspace.firstWeekday == 4)
            #expect(t.workspace.snapshot?.tasks.first(where: { $0.id == id })?.name == "Accepted")
            #expect(t.workspace.snapshot?.revision == before.revision + 2)
            #expect(t.workspace.snapshot?.activeTimer != nil)
            #expect(t.workspace.issue == nil && host.track.failure == nil)
            #expect(!host.track.acceptedWork && host.acceptingMutations)
            #expect(host.track.begin(host.track.routeToken))
            host.track.complete(host.track.routeToken)
            let resumed = try #require(host.submitFirstWeekday(5))
            try await resumed.value
            #expect(t.workspace.firstWeekday == 5)
            host.invalidate()
        }
    }

    @Test func quitRejectsCallbacksAndPreservesSleepWakeDuringConfirmation() async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace), clock = NativeClock()
            t.workspace.configureTimer(clock: { clock.read() })
            let p = try await project(t), id = try await task(t, project: p)
            host.submitTimer(.start(taskID: id)); await host.drain()
            host.track.editProject(p)
            let token = host.track.routeToken, before = t.workspace.snapshot
            let lifecycle = Lifecycle(host: host), confirmation = NativeSubmissionGate()
            lifecycle.confirmQuit = { await confirmation.pause(); return true }
            var closes = 0
            lifecycle.close = { _ in closes += 1 }
            await withCheckedContinuation { done in
                lifecycle.reply = { ok in #expect(!ok); done.resume() }
                lifecycle.requestQuit()
                Task { @MainActor in
                    await confirmation.waitForArrival()
                    #expect(!host.track.begin(token))
                    host.track.timer(.stop(expectedEntryID: nil))
                    host.track.undoMigration(receiptID: UUID())
                    host.track.undoCorrection(); host.track.undoTimeReview()
                    #expect(host.submitFirstWeekday(6) == nil)
                    #expect(!t.workspace.isBusy && t.workspace.snapshot == before)
                    clock.set(110); lifecycle.willSleep()
                    lifecycle.didWake(at: Date(timeIntervalSince1970: 120))
                    await confirmation.release()
                }
            }
            #expect(closes == 0 && host.acceptingMutations)
            let resumed = try #require(t.workspace.snapshot?.activeTimer)
            #expect(resumed.entryID != before?.activeTimer?.entryID && resumed.checkpointAt == 120)
            #expect(t.workspace.snapshot?.entries.first(where: { $0.id == resumed.entryID })?.taskID == id)
            #expect(t.workspace.snapshot?.entries.first(where: { $0.id == before?.activeTimer?.entryID })?.endAt == 110)
            #expect(t.workspace.snapshot?.pendingSleepIntervals.first?.sleepAt == 110)
            #expect(t.workspace.snapshot?.pendingSleepIntervals.first?.wakeAt == 120)
            #expect(host.track.sheet?.id == p && !host.track.acceptedWork)
            #expect(host.track.begin(token))
            host.track.complete(token)
            host.invalidate()
        }
    }

    @Test func quitCancelStopFailureAndCloseFailureNeverReplay() async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace), clock = NativeClock()
            t.workspace.configureTimer(clock: { clock.read() })
            let p = try await project(t), id = try await task(t, project: p)
            host.submitTimer(.start(taskID: id)); await host.drain()
            let lifecycle = Lifecycle(host: host)
            var closes = 0, replies = 0, opens = 0
            host.installSceneActions(workspace: { opens += 1 }, settings: {})
            lifecycle.close = { _ in closes += 1 }
            lifecycle.confirmQuit = { false }
            await withCheckedContinuation { done in
                lifecycle.reply = { ok in #expect(!ok); replies += 1; done.resume() }
                lifecycle.requestQuit()
            }
            #expect(closes == 0); #expect(host.acceptingMutations)
            lifecycle.confirmQuit = { true }
            t.workspace.configureTimer(clock: { clock.read() }, write: { _, _, _, _, _ in throw StorageError.injectedFailure })
            await withCheckedContinuation { done in
                lifecycle.reply = { ok in #expect(!ok); replies += 1; done.resume() }
                lifecycle.requestQuit()
            }
            #expect(closes == 0); #expect(t.workspace.snapshot?.activeTimer != nil)
            clock.set(110)
            t.workspace.configureTimer(clock: { clock.read() }, write: { library, command, revision, instant, entry in
                try await library.performTimer(command, expectedRevision: revision, instant: instant, newEntryID: entry)
            })
            lifecycle.close = { model in
                closes += 1; await model.close(); throw LibraryAccessError.unavailable
            }
            await withCheckedContinuation { done in
                lifecycle.reply = { ok in #expect(!ok); replies += 1; done.resume() }
                lifecycle.requestQuit()
            }
            #expect(replies == 3); #expect(closes == 1); #expect(opens > 0)
            #expect(!host.acceptingMutations); #expect(!host.recoveryDetails.isEmpty)
            host.reopen(); await host.drain()
            #expect(host.acceptingMutations); #expect(t.workspace.snapshot?.activeTimer != nil)
            #expect(t.workspace.snapshot?.entries.last?.endAt == nil) // Paused timer is left unchanged for review.
            host.invalidate()
        }
    }

    @Test func notificationsConsentDedupAndDefensiveResponses() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), id = try await task(t, project: p)
            var prompts = 0, delivered: [UNNotificationRequest] = [], revealed: [UUID] = []
            let notifications = BudgetNotifications(path: { _ in "Project / Parent / Task" }, reveal: { revealed.append($0) },
                authorizationStatus: { .notDetermined }, requestAuthorization: { prompts += 1; return true },
                deliver: { delivered.append($0) })
            let batch = BudgetWarningBatch(id: UUID(), warnings: [BudgetWarning(taskID: id, threshold: .eighty)])
            let baseline = try #require(t.workspace.snapshot)
            notifications.consume(snapshot: baseline, batches: [batch])
            await notifications.waitForPendingDelivery()
            #expect(prompts == 0); #expect(delivered.isEmpty)
            let enabled = LibrarySnapshot(schemaVersion: 2, revision: baseline.revision + 1,
                projects: baseline.projects,
                tasks: [TaskRecord(id: id, projectID: p, name: "Task", budgetMinutes: 100)],
                entries: [], activeTimer: nil, pendingSleepIntervals: [])
            let fresh = BudgetWarningBatch(id: UUID(), warnings: batch.warnings)
            notifications.consume(snapshot: enabled, batches: [batch, fresh])
            notifications.consume(snapshot: enabled, batches: [batch, fresh])
            await notifications.waitForPendingDelivery()
            #expect(prompts == 1); #expect(delivered.count == 1)
            #expect(delivered[0].content.sound != nil)
            #expect(delivered.first?.content.body.contains("Project / Parent / Task") == true)
            #expect(BudgetNotifications.taskIDs(in: delivered[0].content.userInfo) == [id])
            for malformed: [AnyHashable: Any] in [[:], ["taskIDs": "bad"], ["taskIDs": ["bad"]],
                ["taskIDs": [id.uuidString.lowercased(), id.uuidString.lowercased()]], ["taskIDs": []]] {
                #expect(BudgetNotifications.taskIDs(in: malformed) == nil)
            }
            notifications.consume(snapshot: nil, batches: [])
            notifications.consume(snapshot: enabled, batches: [fresh])
            await notifications.waitForPendingDelivery()
            #expect(delivered.count == 1); #expect(revealed.isEmpty)
            var completions = 0
            notifications.handleResponse(actionIdentifier: UNNotificationDefaultActionIdentifier,
                userInfo: ["taskIDs": [id.uuidString.lowercased()]], completion: { completions += 1 })
            notifications.handleResponse(actionIdentifier: UNNotificationDismissActionIdentifier,
                userInfo: ["taskIDs": [id.uuidString.lowercased()]], completion: { completions += 1 })
            notifications.handleResponse(actionIdentifier: UNNotificationDefaultActionIdentifier,
                userInfo: ["taskIDs": ["invalid"]], completion: { completions += 1 })
            #expect(completions == 3)
            // Queue behind the response's MainActor hop, without a notification daemon.
            await Task { @MainActor in }.value
            #expect(revealed == [id])

            var deniedPrompts = 0, deniedDeliveries = 0
            let denied = BudgetNotifications(path: { _ in "Task" }, reveal: { _ in },
                authorizationStatus: { .notDetermined },
                requestAuthorization: { deniedPrompts += 1; return false },
                deliver: { _ in deniedDeliveries += 1 })
            denied.consume(snapshot: baseline, batches: [])
            denied.consume(snapshot: enabled, batches: [fresh])
            denied.consume(snapshot: enabled, batches: [fresh])
            await denied.waitForPendingDelivery()
            #expect(deniedPrompts == 1); #expect(deniedDeliveries == 0)
        }
    }

    @Test func savedPendingReviewDefersUnbilledAndStopsOwnedTimerOnce() async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace), clock = NativeClock()
            t.workspace.configureTimer(clock: { clock.read() })
            let p = try await project(t), id = try await task(t, project: p)
            host.submitTimer(.start(taskID: id)); await host.drain()
            let lifecycle = Lifecycle(host: host)
            clock.set(110); lifecycle.willSleep(); await host.drain()
            lifecycle.didWake(at: Date(timeIntervalSince1970: 120)); await host.drain()
            let before = try #require(t.workspace.snapshot)
            #expect(before.pendingSleepIntervals.count == 1)
            let writes = NativeQuitWriteProbe()
            let expectedStop = host.track.ownedStop
            var closes = 0, replies = 0
            t.workspace.configureTimer(clock: { 130 }, write: { library, command, revision, instant, entry in
                writes.record()
                #expect(command == expectedStop)
                return try await library.performTimer(command, expectedRevision: revision, instant: instant, newEntryID: entry)
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
                lifecycle.reply = { ok in #expect(ok); replies += 1; done.resume() }
                lifecycle.requestQuit(); lifecycle.requestQuit()
            }
            #expect(writes.count == 1 && closes == 1 && replies == 1)
            lifecycle.requestQuit()
            #expect(closes == 1 && replies == 1)
            try await t.workspace.open()
            #expect(t.workspace.snapshot?.pendingSleepIntervals == before.pendingSleepIntervals)
            #expect(t.workspace.snapshot?.activeTimer == nil)
            #expect(lifecycle.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared) == false)
            host.invalidate()
        }
    }

    @Test func sleepingUnknownEndClosesWithoutInferringBounds() async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace), clock = NativeClock()
            t.workspace.configureTimer(clock: { clock.read() })
            let p = try await project(t), id = try await task(t, project: p)
            host.submitTimer(.start(taskID: id)); await host.drain()
            let lifecycle = Lifecycle(host: host)
            clock.set(110); lifecycle.willSleep(); await host.drain()
            let before = try #require(t.workspace.snapshot)
            #expect(before.pendingSleepIntervals.first?.wakeAt == nil)
            let writes = NativeQuitWriteProbe()
            t.workspace.configureTimer(clock: { 999 }, write: { _, _, _, _, _ in
                writes.record(); throw StorageError.injectedFailure
            })
            lifecycle.confirmQuit = { true }
            lifecycle.close = { model in
                #expect(model.snapshot == before)
                await model.close()
            }
            await withCheckedContinuation { done in
                lifecycle.reply = { ok in #expect(ok); done.resume() }
                lifecycle.requestQuit()
            }
            #expect(writes.count == 0)
            try await t.workspace.open()
            #expect(t.workspace.snapshot == before)
            host.invalidate()
        }
    }

    @Test func unavailableQuitDoesNotReopenOrMutate() async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace)
            let p = try await project(t), id = try await task(t, project: p)
            host.submitTimer(.start(taskID: id)); await host.drain()
            let before = try #require(t.workspace.snapshot)
            await t.workspace.close()
            let writes = NativeQuitWriteProbe()
            var closes = 0
            t.workspace.configureTimer(clock: { 999 }, write: { _, _, _, _, _ in
                writes.record(); throw StorageError.injectedFailure
            })
            let lifecycle = Lifecycle(host: host)
            lifecycle.confirmQuit = { true }
            lifecycle.close = { model in closes += 1; await model.close() }
            await withCheckedContinuation { done in
                lifecycle.reply = { ok in #expect(ok); done.resume() }
                lifecycle.requestQuit()
            }
            #expect(writes.count == 0 && closes == 1)
            try await t.workspace.open() // Test inspection, never a Quit recovery action.
            #expect(t.workspace.snapshot == before)
            host.invalidate()
        }
    }

    @Test func uncertainQuitRetainsUncertaintyAndNeverResubmits() async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace)
            let clock = NativeClock()
            t.workspace.configureTimer(clock: { clock.read() })
            let p = try await project(t), id = try await task(t, project: p)
            host.submitTimer(.start(taskID: id)); await host.drain()
            let before = try #require(t.workspace.snapshot)
            let writes = NativeQuitWriteProbe()
            var closes = 0
            t.workspace.configureTimer(clock: { 110 }, write: { _, _, _, _, _ in
                writes.record(); throw LibraryAccessError.publicationIndeterminate
            })
            host.submitTimer(.checkpoint); await host.drain()
            #expect(host.hasUncertainPublication)
            #expect(t.workspace.snapshot == before)
            // Phase 7 tests separately cover a later issue replacing uncertainSave.
            let lifecycle = Lifecycle(host: host)
            lifecycle.confirmQuit = { #expect(host.hasUncertainPublication); return true }
            lifecycle.close = { model in
                closes += 1
                #expect(model.snapshot == before && model.publicationUncertain)
                await model.close()
            }
            await withCheckedContinuation { done in
                lifecycle.reply = { ok in #expect(ok); done.resume() }
                lifecycle.requestQuit()
            }
            #expect(writes.count == 1 && closes == 1)
            #expect(host.hasUncertainPublication) // Close is not confirmed inspection/reopen.
            host.invalidate()
        }
    }

    @Test func draftCancelKeepsSuspendedDraftRouteAndWindow() async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace)
            let p = try await project(t), root = try await task(t, project: p)
            host.track.newTask(projectID: p, parentID: root)
            guard case .task(var draft) = host.track.sheet else { Issue.record("Missing draft"); return }
            draft.name = "Unsent child"; host.track.updateTaskDraft(draft)
            host.track.editConstrainingBudget(taskID: root)
            let token = host.track.routeToken, sheet = host.track.sheet?.id
            let before = t.workspace.snapshot
            var opens = 0, closes = 0
            host.installSceneActions(workspace: { opens += 1 }, settings: {})
            let lifecycle = Lifecycle(host: host)
            lifecycle.confirmQuit = { #expect(!host.track.acceptedWork); return false }
            lifecycle.close = { _ in closes += 1 }
            await withCheckedContinuation { done in
                lifecycle.reply = { ok in #expect(!ok); done.resume() }
                lifecycle.requestQuit()
            }
            #expect(closes == 0 && opens == 0 && host.acceptingMutations)
            #expect(host.track.routeToken == token && host.track.sheet?.id == sheet)
            #expect(host.track.suspendedTaskDraft?.name == "Unsent child")
            #expect(t.workspace.snapshot == before)
            host.invalidate()
        }
    }

    @Test func failedOwnedStopRequiresAnotherExplicitQuitWithoutReplay() async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace)
            let clock = NativeClock()
            t.workspace.configureTimer(clock: { clock.read() })
            let p = try await project(t), id = try await task(t, project: p)
            host.submitTimer(.start(taskID: id)); await host.drain()
            let before = t.workspace.snapshot
            let writes = NativeQuitWriteProbe()
            var closes = 0, confirms = 0
            t.workspace.configureTimer(clock: { 110 }, write: { _, _, _, _, _ in
                writes.record(); throw StorageError.injectedFailure
            })
            let lifecycle = Lifecycle(host: host)
            lifecycle.confirmQuit = { confirms += 1; return true }
            lifecycle.close = { model in closes += 1; await model.close() }
            await withCheckedContinuation { done in
                lifecycle.reply = { ok in #expect(!ok); done.resume() }
                lifecycle.requestQuit()
            }
            #expect(writes.count == 1 && closes == 0 && host.acceptingMutations)
            #expect(t.workspace.snapshot == before)
            #expect(host.track.failure?.contains("Stop was not confirmed") == true)
            await withCheckedContinuation { done in
                lifecycle.reply = { ok in #expect(ok); done.resume() }
                lifecycle.requestQuit()
            }
            #expect(confirms == 2 && writes.count == 1 && closes == 1)
            try await t.workspace.open()
            #expect(t.workspace.snapshot == before) // Paused timer left for review, not checkpoint-stopped.
            host.invalidate()
        }
    }

    @Test func lateLifecycleWorkDuringCloseIsNotAcceptedOrReplayed() async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace)
            let gate = NativeSubmissionGate(), lifecycle = Lifecycle(host: host)
            let before = t.workspace.snapshot
            var closes = 0, replies = 0
            lifecycle.close = { model in
                closes += 1
                await gate.pause() // Close adapter suspended before even submitting workspace close.
                #expect(model.snapshot == before && !model.isBusy)
                await model.close()
            }
            await withCheckedContinuation { done in
                lifecycle.reply = { ok in #expect(ok); replies += 1; done.resume() }
                lifecycle.requestQuit()
                Task { @MainActor in
                    await gate.waitForArrival()
                    lifecycle.willSleep(); lifecycle.didWake(at: Date(timeIntervalSince1970: 120))
                    lifecycle.checkpointTick(); lifecycle.budgetTick(); lifecycle.requestQuit()
                    #expect(!host.workspace.isBusy && !host.acceptingMutations)
                    await gate.release()
                }
            }
            #expect(closes == 1 && replies == 1)
            host.invalidate()
        }
    }

    @Test func sleepAcceptedDuringDrainIsReviewedBeforeConfirmation() async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace), clock = NativeClock()
            t.workspace.configureTimer(clock: { clock.read() })
            let p = try await project(t), id = try await task(t, project: p)
            host.submitTimer(.start(taskID: id)); await host.drain()
            let gate = NativeSubmissionGate(), lifecycle = Lifecycle(host: host)
            t.workspace.configureTimer(clock: { clock.read() }, write: { library, command, revision, instant, entry in
                await gate.pause()
                return try await library.performTimer(command, expectedRevision: revision, instant: instant, newEntryID: entry)
            })
            clock.set(105); host.submitTimer(.checkpoint)
            await gate.waitForArrival()
            var closes = 0, replies = 0
            lifecycle.confirmQuit = {
                #expect(t.workspace.snapshot?.pendingSleepIntervals.first?.sleepAt == 110)
                #expect(t.workspace.snapshot?.pendingSleepIntervals.first?.wakeAt == nil)
                #expect(!t.workspace.isBusy)
                return false
            }
            lifecycle.close = { _ in closes += 1 }
            await withCheckedContinuation { done in
                lifecycle.reply = { ok in #expect(!ok); replies += 1; done.resume() }
                lifecycle.requestQuit()
                clock.set(110); lifecycle.willSleep()
                Task { await gate.release() }
            }
            #expect(closes == 0 && replies == 1 && host.acceptingMutations)
            #expect(t.workspace.snapshot?.activeTimer == nil)
            #expect(t.workspace.snapshot?.pendingSleepIntervals.first?.wakeAt == nil)
            host.invalidate()
        }
    }

    @Test func restoredUnownedTimerClosesUnchanged() async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace)
            let p = try await project(t), id = try await task(t, project: p)
            host.submitTimer(.start(taskID: id)); await host.drain()
            await t.workspace.close(); try await t.workspace.open()
            let before = try #require(t.workspace.snapshot)
            #expect(before.activeTimer != nil && host.track.ownedStop == nil)
            let writes = NativeQuitWriteProbe()
            t.workspace.configureTimer(clock: { 999 }, write: { _, _, _, _, _ in
                writes.record(); throw StorageError.injectedFailure
            })
            let lifecycle = Lifecycle(host: host)
            lifecycle.confirmQuit = { true }
            lifecycle.close = { model in #expect(model.snapshot == before); await model.close() }
            await withCheckedContinuation { done in
                lifecycle.reply = { ok in #expect(ok); done.resume() }
                lifecycle.requestQuit()
            }
            #expect(writes.count == 0)
            try await t.workspace.open()
            #expect(t.workspace.snapshot == before)
            host.invalidate()
        }
    }

    @Test(arguments: [false, true])
    func unsentDraftIsNotRemovedBeforeCloseOutcome(closeFails: Bool) async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace)
            let p = try await project(t)
            host.track.editProject(p)
            let token = host.track.routeToken, before = t.workspace.snapshot
            let lifecycle = Lifecycle(host: host)
            lifecycle.confirmQuit = { #expect(!host.track.acceptedWork); return true }
            lifecycle.close = { model in
                #expect(host.track.sheet?.id == p && host.track.routeToken == token)
                #expect(model.snapshot == before)
                if closeFails { throw LibraryAccessError.unavailable }
                await model.close()
            }
            await withCheckedContinuation { done in
                lifecycle.reply = { ok in #expect(ok == !closeFails); done.resume() }
                lifecycle.requestQuit()
            }
            #expect(host.track.sheet?.id == p && host.track.routeToken == token)
            if closeFails {
                #expect(host.acceptingMutations && t.workspace.snapshot == before)
            } else {
                #expect(t.workspace.availability == .closed)
            }
            host.invalidate()
        }
    }

    @Test(arguments: [false, true])
    func failedCloseReconcilesPhysicalSleepWithoutReplay(wakeDuringClose: Bool) async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace)
            let clock = NativeClock(), writes = NativeQuitWriteProbe()
            t.workspace.configureTimer(clock: { clock.read() })
            let p = try await project(t), id = try await task(t, project: p)
            host.submitTimer(.start(taskID: id)); await host.drain()
            clock.set(105)
            t.workspace.configureTimer(clock: { clock.read() }, write: { _, _, _, _, _ in
                writes.record(); throw StorageError.injectedFailure
            })
            host.submitTimer(.checkpoint); await host.drain()
            let before = try #require(t.workspace.snapshot)
            let active = try #require(before.activeTimer)
            #expect(t.workspace.timerStatus == .paused(entryID: active.entryID))
            let lifecycle = Lifecycle(host: host), gate = NativeSubmissionGate()
            host.installSceneActions(workspace: {}, settings: {})
            var closes = 0, replies = 0
            lifecycle.confirmQuit = { true }
            lifecycle.close = { _ in
                closes += 1
                await gate.pause()
                throw LibraryAccessError.unavailable
            }
            await withCheckedContinuation { done in
                lifecycle.reply = { ok in #expect(!ok); replies += 1; done.resume() }
                lifecycle.requestQuit()
                Task { @MainActor in
                    await gate.waitForArrival()
                    clock.set(110); lifecycle.willSleep()
                    if wakeDuringClose { lifecycle.didWake(at: Date(timeIntervalSince1970: 120)) }
                    lifecycle.requestQuit(); lifecycle.checkpointTick(); lifecycle.budgetTick()
                    #expect(!t.workspace.isBusy && !host.acceptingMutations)
                    await gate.release()
                }
            }
            #expect(closes == 1 && replies == 1 && writes.count == 1)
            #expect(host.acceptingMutations && t.workspace.snapshot == before)
            #expect(host.track.ownedStop == nil)
            #expect(t.workspace.timerStatus == .reviewRequired)
            #expect(t.workspace.timerLifecycleGate.state().sleeping == !wakeDuringClose)
            if !wakeDuringClose {
                #expect(throws: TimerError.reviewRequired) {
                    try t.workspace.timerLifecycleGate.sample(clock: { 120 })
                }
                lifecycle.didWake(at: Date(timeIntervalSince1970: 120))
            }
            #expect(!lifecycle.sleeping && !host.sleeping)
            #expect(!t.workspace.timerLifecycleGate.state().sleeping)
            #expect(try t.workspace.timerLifecycleGate.sample(clock: { 120 }).instant == 120)
            await #expect(throws: TimerError.reviewRequired) {
                try await t.workspace.enqueueTimer(.checkpoint).value
            }
            #expect(writes.count == 1 && t.workspace.snapshot == before)
            #expect(t.workspace.snapshot?.pendingSleepIntervals.isEmpty == true)
            #expect(t.workspace.timerStatus == .reviewRequired)
            guard case .timeReview = host.track.sheet else { Issue.record("Missing failed-close review"); return }
            #expect(!host.pendingAutoReview && host.track.failure?.contains("Close failed") == true)
            #expect(writes.count == 1 && t.workspace.snapshot == before)
            host.invalidate()
        }
    }
}

private actor NativeRecoveryProbe {
    private var openError: (any Error)?
    private var writeError: (any Error)?
    private var snapshotError: LibraryAccessError?
    private var opens = 0
    private var writes = 0

    init(openError: (any Error)? = nil) { self.openError = openError }
    func setOpenError(_ error: (any Error)?) { openError = error }
    func setFailWrite(_ error: any Error = LibraryAccessError.publicationIndeterminate) { writeError = error }
    func setFailSnapshot(_ fail: Bool, error: LibraryAccessError = .unavailable) {
        snapshotError = fail ? error : nil
    }
    func snapshot(_ library: Library) async throws -> LibrarySnapshot {
        if let snapshotError { throw snapshotError }
        return try await library.snapshot()
    }
    func counts() -> (opens: Int, writes: Int) { (opens, writes) }
    func open(_ directory: URL) async throws -> Library {
        opens += 1
        if let openError { throw openError }
        return try await Library.open(at: directory)
    }
    func perform(_ library: Library, _ command: WorkspaceCommand, _ revision: Int64) async throws -> LibrarySnapshot {
        writes += 1
        if let writeError { throw writeError }
        return try await library.perform(command, expectedRevision: revision)
    }
}

extension NativeHostTests {
    @Test func recoveryMessagesClassifyTypedIssuesWithoutDurabilityClaims() {
        let cases: [(WorkspaceIssue, String)] = [
            (.busy, "Another app or process"),
            (.unsafeLibrary, "could not be opened safely"),
            (.invalidStorage, "unsupported format"),
            (.revisionConflict, "library changed"),
            (.recoveryRequired, "Time needs review"),
            (.uncertainSave, "may or may not have been saved"),
            (.command(.missingRecord), "action could not be completed"),
            (.validation([Violation(.interval)]), "data that could not be accepted"),
            (.unavailable, "library is unavailable"),
            (.closed, "library is unavailable"),
            (.other("raw diagnostic sentinel"), "action could not be completed")
        ]
        for (issue, phrase) in cases {
            let message = NativeHost.recoveryMessage(issue: issue, availability: .blocked)
            #expect(message.contains(phrase))
            #expect(!message.contains("raw diagnostic sentinel"))
        }
        let uncertain = NativeHost.recoveryMessage(issue: .uncertainSave, availability: .blocked)
        #expect(uncertain.contains("Do not repeat it"))
        #expect(uncertain.contains("or assume it is safe to discard"))
        #expect(!uncertain.contains("successfully saved"))
        #expect(NativeHost.recoveryMessage(issue: .validation([Violation(.task)]), availability: .ready)
            .contains("affected fields"))
        #expect(NativeHost.recoveryMessage(issue: nil, availability: .opening).contains("Opening"))
        #expect(NativeHost.recoveryMessage(issue: .busy, availability: .opening).contains("Opening"))
        #expect(NativeHost.recoveryMessage(issue: nil, availability: .closing).contains("Closing"))
        #expect(NativeHost.recoveryMessage(issue: nil, availability: .closed).contains("closed"))
        #expect(NativeHost.recoveryMessage(issue: nil, availability: .blocked).contains("blocked"))
        #expect(NativeHost.recoveryMessage(issue: nil, availability: .reviewRequired).contains("unbilled"))
        let stale = NativeHost.recoveryMessage(issue: .revisionConflict, availability: .blocked)
        #expect(stale.contains("Retained rows may be stale"))
        #expect(stale.contains("reopen and inspect"))
        #expect(!stale.contains("current rows"))
    }

    @Test func openFailuresUseActualDirectoryAndKeepDiagnosticsSeparate() async throws {
        let failures: [(any Error, WorkspaceIssue)] = [
            (LibraryOpenError.busy, .busy),
            (LibraryOpenError.unsafeState("unsafe sentinel"), .unsafeLibrary),
            (StorageError.invalidStorage("invalid sentinel"), .invalidStorage),
            (StorageError.unsupportedSchema(999), .invalidStorage),
            (LibraryError.invalid([Violation(.interval)]), .validation([Violation(.interval)])),
            (LibraryOpenError.filesystem("filesystem sentinel", 13),
             .other(String(describing: LibraryOpenError.filesystem("filesystem sentinel", 13))))
        ]
        for (error, expected) in failures {
            let directory = fixtureTemporaryDirectory().appendingPathComponent("RecoveryActual.\(UUID())", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let suite = "NativeRecovery.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let probe = NativeRecoveryProbe(openError: error)
            var operations = WorkspaceOperations()
            operations.open = { try await probe.open($0) }
            let workspace = WorkspaceModel(directory: directory, operations: operations)
            let host = NativeHost(directory: directory, workspace: workspace, defaults: defaults)
            defer { host.invalidate() }
            #expect(host.canReopen)
            let _ = WorkspaceView(host: host) { Text("Reports") }
            host.reopen()
            #expect(workspace.availability == .opening)
            #expect(!host.canReopen)
            host.reopen() // Opening is not another accepted open.
            await host.drain()
            #expect(workspace.issue == expected)
            #expect(workspace.availability == .blocked)
            #expect(workspace.snapshot == nil)
            #expect(host.directory == directory)
            #expect(host.recoveryDiagnostics.contains("Library: \(directory.path)"))
            #expect(host.recoveryDiagnostics.contains("No confirmed snapshot"))
            #expect(host.recoveryDiagnostics.contains("Workspace issue:"))
            #expect(!host.recoveryMessage.contains("sentinel"))
            #expect(host.canReopen) // A completed lock-busy failure is retryable, not in-flight work.
            #expect(!workspace.isBusy && host.hasRecoveryFeedback)
            #expect(host.reopenFailure != nil && host.track.failure == nil)
            #expect(host.recoveryDiagnostics.contains("Last explicit reopen error (historical):"))
            for _ in 0..<3 {
                _ = host.recoveryMessage; _ = host.recoveryDiagnostics
            }
            let counts = await probe.counts()
            #expect(counts.opens == 1 && counts.writes == 0)
            await workspace.close()
        }
    }

    @Test func uncertainWriteAndFailedReopenKeepConfirmedRowsAndNeverReplay() async throws {
        let directory = fixtureTemporaryDirectory().appendingPathComponent("RecoveryActual.\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "NativeRecovery.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = NativeRecoveryProbe()
        var operations = WorkspaceOperations()
        operations.open = { try await probe.open($0) }
        operations.perform = { try await probe.perform($0, $1, $2) }
        let workspace = WorkspaceModel(directory: directory, operations: operations)
        let host = NativeHost(directory: directory, workspace: workspace, defaults: defaults)
        defer { host.invalidate() }
        host.reopen(); await host.drain()
        #expect(host.available && !host.canReopen)
        let initial = try #require(workspace.snapshot)
        _ = try await workspace.submit(.createProject(id: UUID(), name: "Confirmed", rate: 100, currency: "EUR"),
                                       expectedRevision: initial.revision)
        let before = try #require(workspace.snapshot)
        await probe.setFailWrite()
        do {
            _ = try await workspace.submit(.createProject(id: UUID(), name: "Uncertain", rate: 100, currency: "EUR"),
                                           expectedRevision: before.revision)
            Issue.record("Expected uncertain publication")
        } catch {
            #expect((error as? LibraryAccessError) == .publicationIndeterminate)
        }
        #expect(workspace.issue == .uncertainSave)
        #expect(workspace.availability == .blocked)
        #expect(workspace.snapshot == before)
        #expect(host.recoveryDiagnostics.contains("Last confirmed revision: \(before.revision)"))
        #expect(host.recoveryMessage.contains("may or may not"))
        #expect(workspace.publicationUncertain && host.hasUncertainPublication) // Latched at issue assignment, not reopen.
        var counts = await probe.counts()
        #expect(counts.opens == 1 && counts.writes == 2)
        await probe.setOpenError(LibraryOpenError.busy)
        host.reopen()
        #expect(workspace.availability == .opening && !host.canReopen)
        #expect(host.hasUncertainPublication && host.recoveryMessage.contains("Do not repeat it"))
        host.reopen(); await host.drain()
        #expect(workspace.issue == .busy)
        #expect(workspace.availability == .blocked)
        #expect(workspace.snapshot == before)
        #expect(host.reopenFailure != nil && host.track.failure == nil)
        #expect(host.hasUncertainPublication && host.hasRecoveryFeedback && host.canReopen)
        #expect(host.recoveryMessage.contains("may or may not have been saved"))
        #expect(host.recoveryMessage.contains("Do not repeat it"))
        #expect(host.recoveryMessage.contains("or assume it is safe to discard"))
        #expect(host.recoveryDiagnostics.contains("Unresolved publication uncertainty:"))
        #expect(host.recoveryDiagnostics.contains("Last explicit reopen error (historical):"))
        counts = await probe.counts()
        #expect(counts.opens == 2 && counts.writes == 2)
        for _ in 0..<5 { _ = host.recoveryMessage; _ = host.recoveryDiagnostics }
        counts = await probe.counts()
        #expect(counts.opens == 2 && counts.writes == 2)
        await probe.setOpenError(nil)
        host.track.failure = "Unsent draft error sentinel"
        host.reopen()
        #expect(host.hasUncertainPublication && host.recoveryMessage.contains("Do not repeat it"))
        await host.drain()
        #expect(host.available && !host.canReopen)
        #expect(workspace.issue == nil)
        #expect(!host.hasUncertainPublication && host.reopenFailure == nil)
        #expect(!host.recoveryMessage.contains("may or may not"))
        #expect(!host.recoveryDiagnostics.contains("Last explicit reopen error"))
        #expect(host.track.failure == "Unsent draft error sentinel")
        #expect(host.recoveryDiagnostics.contains("Last editor/action error (historical; inspect the affected draft):"))
        #expect(host.recoveryMessage.contains("historical feedback"))
        host.track.failure = nil // Test-only cleanup; production reopen must not clear another error.
        #expect(!host.hasRecoveryFeedback)
        #expect(workspace.snapshot == before)
        counts = await probe.counts()
        #expect(counts.opens == 3 && counts.writes == 2)
        // A healthy workspace cannot be reopened through this recovery action either.
        host.reopen(); await host.drain()
        counts = await probe.counts()
        #expect(counts.opens == 3 && counts.writes == 2)
        await workspace.close()
        #expect(host.canReopen)
        let token = try #require(host.beginQuit())
        #expect(!host.canReopen)
        host.reopen(); await host.drain()
        counts = await probe.counts()
        #expect(counts.opens == 3 && counts.writes == 2)
        host.finishQuit(token, cancelled: true)
        #expect(host.canReopen)
    }

    @Test(arguments: [false, true])
    func acceptedSuccessorCannotEraseUncertaintyBeforeHostReopen(storageFailure: Bool) async throws {
        let directory = fixtureTemporaryDirectory().appendingPathComponent("RecoveryQueued.\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "NativeRecovery.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = NativeRecoveryProbe()
        var operations = WorkspaceOperations()
        operations.open = { try await probe.open($0) }
        operations.perform = { try await probe.perform($0, $1, $2) }
        let workspace = WorkspaceModel(directory: directory, operations: operations)
        let host = NativeHost(directory: directory, workspace: workspace, defaults: defaults)
        defer { host.invalidate() }
        host.reopen(); await host.drain()
        let before = try #require(workspace.snapshot)
        #expect(!workspace.publicationUncertain && !host.hasUncertainPublication)
        if storageFailure { await probe.setFailWrite(StorageError.commitIndeterminate) }
        else { await probe.setFailWrite() }
        // Both accepted on MainActor without a suspension: the successor runs in the real FIFO.
        let uncertain = workspace.enqueueSubmit(
            .createProject(id: UUID(), name: "Unknown", rate: 1, currency: "EUR"),
            expectedRevision: before.revision)
        let successor = workspace.enqueueSubmit(
            .createProject(id: UUID(), name: "Must not write", rate: 1, currency: "EUR"),
            expectedRevision: before.revision)
        #expect(workspace.isBusy)
        do {
            _ = try await uncertain.value
            Issue.record("Expected uncertain publication")
        } catch {
            if storageFailure { #expect((error as? StorageError) == .commitIndeterminate) }
            else { #expect((error as? LibraryAccessError) == .publicationIndeterminate) }
        }
        do {
            _ = try await successor.value
            Issue.record("Expected queued successor to fail before its writer")
        } catch { #expect((error as? LibraryAccessError) == .unavailable) }
        // No host.reopen has occurred since the uncertain write. Its old capture-only latch would miss this.
        #expect(workspace.issue == .unavailable && workspace.availability == .blocked)
        #expect(workspace.snapshot == before && !workspace.isBusy)
        #expect(workspace.publicationUncertain && host.hasUncertainPublication)
        #expect(host.recoveryMessage.contains("Do not repeat it"))
        var counts = await probe.counts()
        #expect(counts.opens == 1 && counts.writes == 1)
        await probe.setOpenError(LibraryOpenError.busy)
        host.reopen()
        #expect(workspace.publicationUncertain && host.hasUncertainPublication)
        await host.drain()
        #expect(workspace.issue == .busy && workspace.snapshot == before)
        #expect(workspace.publicationUncertain && host.hasUncertainPublication)
        #expect(host.reopenFailure != nil && host.canReopen)
        #expect(host.recoveryMessage.contains("or assume it is safe to discard"))
        counts = await probe.counts()
        #expect(counts.opens == 2 && counts.writes == 1)
        await workspace.close()
        #expect(workspace.issue == nil && workspace.snapshot == nil)
        #expect(workspace.publicationUncertain && host.hasUncertainPublication) // Shutdown is not confirmation.
        await probe.setOpenError(nil)
        host.reopen()
        #expect(workspace.publicationUncertain && host.hasUncertainPublication)
        await host.drain()
        #expect(host.available && workspace.snapshot == before && workspace.issue == nil)
        #expect(!workspace.publicationUncertain && !host.hasUncertainPublication)
        #expect(host.reopenFailure == nil)
        counts = await probe.counts()
        #expect(counts.opens == 3 && counts.writes == 1) // Inspection never replays either queued mutation.
        await workspace.close()
    }

    @Test func confirmedOpenCannotClearUncertaintyAcrossAcceptedClose() async throws {
        let directory = fixtureTemporaryDirectory().appendingPathComponent("RecoveryClosing.\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "NativeRecovery.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = NativeRecoveryProbe(openError: LibraryAccessError.publicationIndeterminate)
        let openingGate = NativeSubmissionGate(), closingGate = NativeSubmissionGate()
        var operations = WorkspaceOperations()
        operations.open = { try await probe.open($0) }
        operations.settings = { library in
            await openingGate.pause()
            return try await library.settings()
        }
        operations.close = { library in
            await closingGate.pause()
            await library.close()
        }
        let workspace = WorkspaceModel(directory: directory, operations: operations)
        let host = NativeHost(directory: directory, workspace: workspace, defaults: defaults)
        defer { host.invalidate() }
        host.reopen(); await host.drain()
        #expect(workspace.availability == .blocked && workspace.snapshot == nil)
        #expect(workspace.publicationUncertain && host.hasUncertainPublication)
        await probe.setOpenError(nil)
        let opening = workspace.enqueueOpen()
        let openingCompletion = Task { @MainActor in
            do { try await opening.value }
            catch {
                // Surface setup failures even when open never reaches the settings gate.
                await openingGate.pause()
                throw error
            }
        }
        await openingGate.waitForArrival()
        let closing = workspace.enqueueClose() // Accepted while the real open is suspended.
        #expect(workspace.availability == .closing && !host.canReopen)
        await openingGate.release()
        try await openingCompletion.value
        await closingGate.waitForArrival() // Keep confirmed open rows visible while close is in flight.
        #expect(workspace.snapshot != nil && workspace.issue == nil)
        #expect(workspace.availability == .closing)
        #expect(workspace.publicationUncertain && host.hasUncertainPublication)
        #expect(host.recoveryMessage.contains("Do not repeat it"))
        await closingGate.release()
        await closing.value
        #expect(workspace.availability == .closed && workspace.snapshot == nil)
        #expect(workspace.publicationUncertain && host.hasUncertainPublication)
        let counts = await probe.counts()
        #expect(counts.opens == 2 && counts.writes == 0)
    }

    @Test(arguments: [LibraryAccessError.unavailable, .publicationIndeterminate])
    func failedConflictRefreshIsStaleAndIssueFreeReviewStillHasFeedback(refreshError: LibraryAccessError) async throws {
        let directory = fixtureTemporaryDirectory().appendingPathComponent("RecoveryActual.\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "NativeRecovery.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = NativeRecoveryProbe()
        var operations = WorkspaceOperations()
        operations.open = { try await probe.open($0) }
        operations.snapshot = { try await probe.snapshot($0) }
        let workspace = WorkspaceModel(directory: directory, operations: operations)
        let host = NativeHost(directory: directory, workspace: workspace, defaults: defaults)
        defer { host.invalidate() }
        host.reopen(); await host.drain()
        let p = try await project(host.track), id = try await task(host.track, project: p)
        workspace.configureTimer(clock: { 100 })
        host.submitTimer(.start(taskID: id)); await host.drain()
        let before = try #require(workspace.snapshot)
        await probe.setFailSnapshot(true, error: refreshError)
        workspace.configureTimer(clock: { 110 }, write: { _, _, revision, _, _ in
            throw StorageError.revisionConflict(expected: revision, actual: revision + 1)
        })
        let conflict = StorageError.revisionConflict(expected: before.revision, actual: before.revision + 1)
        await #expect(throws: conflict) { try await workspace.enqueueTimer(.checkpoint).value }
        #expect(workspace.availability == .blocked)
        #expect(workspace.issue == (refreshError == .publicationIndeterminate ? .uncertainSave : .unavailable))
        #expect(workspace.snapshot == before && host.hasRecoveryFeedback)
        #expect(workspace.publicationUncertain == (refreshError == .publicationIndeterminate))
        #expect(host.hasUncertainPublication == (refreshError == .publicationIndeterminate))
        if refreshError == .publicationIndeterminate {
            #expect(host.recoveryMessage.contains("Do not repeat it"))
        } else {
            #expect(host.recoveryMessage.contains("reopen and inspect"))
        }
        #expect(!host.recoveryMessage.contains("current rows"))
        await probe.setFailSnapshot(false)
        host.reopen(); await host.drain()
        #expect(workspace.availability == .reviewRequired && workspace.issue == nil)
        #expect(host.available && !host.canReopen)
        #expect(!workspace.publicationUncertain && !host.hasUncertainPublication)
        #expect(host.track.failure == nil && host.reopenFailure == nil)
        #expect(host.hasRecoveryFeedback) // Real helper must expose Review time even with no issue/error.
        #expect(host.recoveryMessage.contains("Time needs review"))
        #expect(host.recoveryMessage.contains("unbilled"))
        let counts = await probe.counts()
        #expect(counts.opens == 2 && counts.writes == 0)
        await workspace.close()
    }
}

@MainActor struct DeferredWakeAndNoticeTests {
    @Test func wakeIntentDefersCoalescesAndResumesAfterDraftAndQuit() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            defer { host.invalidate() }
            let clock = NativeClock(), lifecycle = Lifecycle(host: host)
            track.workspace.configureTimer(clock: { clock.read() })
            let p = try await project(track), leaf = try await task(track, project: p)
            host.submitTimer(.start(taskID: leaf)); await host.drain()
            host.track.editProject(p)
            let token = host.track.routeToken
            let quit = try #require(host.beginQuit())
            clock.set(110); lifecycle.willSleep(); await host.drain()
            lifecycle.didWake(at: Date(timeIntervalSince1970: 120)); await host.drain()
            #expect(track.workspace.snapshot?.pendingSleepIntervals.count == 1)
            #expect(host.pendingAutoReview && host.track.routeToken == token)
            host.requestAutoReviewIfNeeded(); host.requestAutoReviewIfNeeded()
            var opens = 0
            host.installSceneActions(workspace: {
                opens += 1
                host.installSceneActions(workspace: { opens += 1 }, settings: {})
            }, settings: {})
            #expect(opens == 0)
            host.track.cancelSheet()
            host.requestAutoReviewIfNeeded()
            #expect(opens == 0 && host.pendingAutoReview)
            let before = track.workspace.snapshot
            host.finishQuit(quit, cancelled: true)
            #expect(opens == 1 && !host.pendingAutoReview)
            guard case .timeReview = host.track.sheet else { Issue.record("Missing automatic review"); return }
            #expect(track.workspace.snapshot == before)
            host.requestAutoReviewIfNeeded()
            #expect(opens == 1 && !host.pendingAutoReview)
        }
    }

    @Test func cancellingFinalSuspendedDraftAutomaticallyRetriesReview() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            defer { host.invalidate() }
            let clock = NativeClock(), lifecycle = Lifecycle(host: host)
            track.workspace.configureTimer(clock: { clock.read() })
            let p = try await project(track), root = try await task(track, project: p, name: "Root")
            let leaf = try await task(track, project: p, parent: root, name: "Leaf")
            host.submitTimer(.start(taskID: leaf)); await host.drain()
            host.track.newTask(projectID: p, parentID: root)
            host.track.editConstrainingBudget(taskID: root)
            var opens = 0
            host.installSceneActions(workspace: { opens += 1 }, settings: {})
            clock.set(110); lifecycle.willSleep(); await host.drain()
            lifecycle.didWake(at: Date(timeIntervalSince1970: 120)); await host.drain()
            #expect(host.pendingAutoReview && opens == 0)
            host.track.cancelSheet()
            #expect(host.track.suspendedTaskDraft == nil && host.track.sheet != nil)
            host.track.cancelSheet()
            // Match the host's observation callback without a timer or polling loop.
            await Task { @MainActor in }.value
            #expect(opens == 1 && !host.pendingAutoReview)
            guard case .timeReview = host.track.sheet else { Issue.record("Missing deferred review"); return }
        }
    }

    @Test func acceptedWorkAndUnavailableLibraryKeepAutomaticIntent() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            defer { host.invalidate() }
            let clock = NativeClock(), lifecycle = Lifecycle(host: host)
            track.workspace.configureTimer(clock: { clock.read() })
            let p = try await project(track), leaf = try await task(track, project: p)
            host.submitTimer(.start(taskID: leaf)); await host.drain()
            host.track.editProject(p)
            let token = host.track.routeToken
            #expect(host.track.begin(token))
            clock.set(110); lifecycle.willSleep(); await host.drain()
            lifecycle.didWake(at: Date(timeIntervalSince1970: 120)); await host.drain()
            var opens = 0
            host.installSceneActions(workspace: { opens += 1 }, settings: {})
            #expect(host.pendingAutoReview && opens == 0 && host.track.acceptedWork)
            await track.workspace.close()
            host.track.complete(token)
            host.requestAutoReviewIfNeeded()
            #expect(opens == 0 && host.pendingAutoReview)
            host.reopen(); await host.drain()
            #expect(opens == 1 && !host.pendingAutoReview)
            guard case .timeReview = host.track.sheet else { Issue.record("Missing reopened review"); return }
        }
    }

    @Test func informationUsesOneShotSinkAndFailuresStayInApp() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            defer { host.invalidate() }
            var messages: [String] = [], ids: [UUID] = []
            host.information = { ids.append($0); messages.append($1) }
            host.track.failure = "Keep this error in the app"
            host.track.feedback = "Created Generic; moved saved entries."
            await Task { @MainActor in }.value
            #expect(messages == ["Created Generic; moved saved entries."] && Set(ids).count == 1)
            #expect(host.track.feedback == nil && host.track.failure != nil && host.hasRecoveryFeedback)
            await Task { @MainActor in }.value
            #expect(messages.count == 1)
        }
    }

    @Test func foregroundNoticesDeduplicateAndDeniedDeliveryDoesNotPrompt() async throws {
        #expect(BudgetNotifications.foregroundOptions == [.banner, .list, .sound])
        var delivered: [UNNotificationRequest] = [], prompts = 0
        let notice = BudgetNotifications(path: { _ in "Task" }, reveal: { _ in },
            authorizationStatus: { .authorized }, requestAuthorization: { prompts += 1; return true },
            deliver: { delivered.append($0) })
        let id = UUID(), taskID = UUID()
        notice.notify(id: id, title: "Created", body: "Moved entries", taskIDs: [taskID])
        notice.notify(id: id, title: "Created", body: "Moved entries", taskIDs: [taskID])
        await notice.waitForPendingDelivery()
        #expect(delivered.count == 1 && prompts == 0)
        #expect(delivered[0].content.sound != nil)
        #expect(BudgetNotifications.taskIDs(in: delivered[0].content.userInfo) == [taskID])
        var attempts = 0
        let denied = BudgetNotifications(path: { _ in "Task" }, reveal: { _ in },
            authorizationStatus: { .denied }, requestAuthorization: { prompts += 1; return true },
            deliver: { _ in attempts += 1 })
        denied.notify(id: UUID(), title: "Created", body: "Task created")
        await denied.waitForPendingDelivery()
        #expect(attempts == 0 && prompts == 0)
        let failing = BudgetNotifications(path: { _ in "Task" }, reveal: { _ in },
            authorizationStatus: { .authorized }, requestAuthorization: { prompts += 1; return true },
            deliver: { _ in attempts += 1; throw LibraryAccessError.unavailable })
        failing.notify(id: id, title: "Created", body: "Task created")
        await failing.waitForPendingDelivery()
        failing.notify(id: id, title: "Created", body: "Task created")
        await failing.waitForPendingDelivery()
        #expect(attempts == 1 && prompts == 0)
    }

    @Test func consumedWarningBatchesAreAcknowledgedBeforeDeliveryAndNeverReplay() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let taskID = try await task(track, project: projectID)
            let snapshot = try #require(track.workspace.snapshot)
            for status: UNAuthorizationStatus in [.authorized, .denied] {
                var attempts = 0
                let notices = BudgetNotifications(path: { _ in "Task" }, reveal: { _ in },
                    authorizationStatus: { status }, requestAuthorization: { false },
                    deliver: { _ in attempts += 1; throw LibraryAccessError.unavailable })
                let baseline = BudgetWarningBatch(id: UUID(), warnings: [
                    BudgetWarning(taskID: taskID, threshold: .eighty)
                ])
                var outstanding = [baseline]
                notices.consume(snapshot: snapshot, batches: outstanding,
                    acknowledge: { id in outstanding.removeAll { $0.id == id } })
                #expect(outstanding.isEmpty && attempts == 0)
                let fresh = BudgetWarningBatch(id: UUID(), warnings: baseline.warnings)
                outstanding = [fresh]
                notices.consume(snapshot: snapshot, batches: outstanding,
                    acknowledge: { id in outstanding.removeAll { $0.id == id } })
                #expect(outstanding.isEmpty && attempts == 0)
                await notices.waitForPendingDelivery()
                #expect(attempts == (status == .authorized ? 1 : 0))
                notices.consume(snapshot: snapshot, batches: [fresh])
                await notices.waitForPendingDelivery()
                #expect(attempts == (status == .authorized ? 1 : 0))
                outstanding = [fresh]
                notices.consume(snapshot: nil, batches: outstanding,
                    acknowledge: { id in outstanding.removeAll { $0.id == id } })
                #expect(outstanding.isEmpty)
            }
        }
    }
}
