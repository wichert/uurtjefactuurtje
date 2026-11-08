import AppKit
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
            #expect(WorkspaceMenu.tasks(host.track, query: "Parent") == [leaf])
            #expect(!WorkspaceMenu.tasks(host.track, query: "").contains(root))
            host.track.cancelSheet()
            host.submitTimer(.start(taskID: leaf)); await host.drain()
            #expect(WorkspaceMenu.tasks(host.track, query: "") == [leaf])
            await t.workspace.close()
            host.revealNotificationTask(leaf)
            host.reopen(); await host.drain()
            #expect(host.track.selectedTaskID == leaf)
            host.revealNotificationTask(UUID()); #expect(host.track.failure?.contains("no longer exists") == true)
            host.invalidate()
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
            #expect(host.acceptingMutations); #expect(t.workspace.snapshot?.activeTimer == nil)
            #expect(t.workspace.snapshot?.entries.isEmpty == true) // Paused Stop uses the zero-duration confirmed checkpoint; no replay.
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
            let enabled = LibrarySnapshot(schemaVersion: 1, revision: baseline.revision + 1,
                projects: baseline.projects,
                tasks: [TaskRecord(id: id, projectID: p, name: "Task", budgetSeconds: 100)],
                entries: [], activeTimer: nil, pendingSleepIntervals: [])
            let fresh = BudgetWarningBatch(id: UUID(), warnings: batch.warnings)
            notifications.consume(snapshot: enabled, batches: [batch, fresh])
            notifications.consume(snapshot: enabled, batches: [batch, fresh])
            await notifications.waitForPendingDelivery()
            #expect(prompts == 1); #expect(delivered.count == 1)
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

    @Test func unresolvedTimeCancelsQuitWithoutClose() async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace), clock = NativeClock()
            t.workspace.configureTimer(clock: { clock.read() })
            let p = try await project(t), id = try await task(t, project: p)
            host.submitTimer(.start(taskID: id)); await host.drain()
            let lifecycle = Lifecycle(host: host)
            lifecycle.confirmQuit = { true }
            var closes = 0
            lifecycle.close = { _ in closes += 1 }
            lifecycle.willSleep(); await host.drain()
            lifecycle.didWake(at: Date(timeIntervalSince1970: 110)); await host.drain()
            await withCheckedContinuation { done in
                lifecycle.reply = { ok in #expect(!ok); done.resume() }
                lifecycle.requestQuit()
            }
            #expect(closes == 0); #expect(host.acceptingMutations)
            #expect(t.workspace.snapshot?.pendingSleepIntervals.isEmpty == false)
            #expect(lifecycle.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared) == false)
            host.invalidate()
        }
    }
}
