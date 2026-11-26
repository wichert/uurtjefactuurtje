import AppKit
import Foundation
import SwiftUI
import Testing
import UserNotifications

@testable import LibraryStore
@testable import UurtjeFactuurtje

@MainActor @Suite(.serialized) struct DeferredWakeAndNoticeTests {
    @Test func wakePresentsOneRecoveryImmediatelyAndPreservesDraft() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            defer { host.invalidate() }
            let clock = NativeClock()
            let lifecycle = Lifecycle(host: host)
            track.workspace.configureTimer(clock: { clock.read() })
            let projectID = try await project(track)
            let leaf = try await task(track, project: projectID)
            host.submitTimer(.start(taskID: leaf))
            await host.drain()
            host.track.editProject(projectID)
            let token = host.track.routeToken
            var presented: [TimeReviewController] = []
            var opens = 0
            host.recoveryPresentationHandler = { presented.append($0) }
            host.installSceneActions(workspace: { opens += 1 }, settings: {})
            clock.set(110)
            lifecycle.willSleep()
            await host.drain()
            lifecycle.didWake(at: Date(timeIntervalSince1970: 120))
            await host.drain()
            #expect(track.workspace.snapshot?.pendingSleepInterval?.wakeAt == 120)
            #expect(presented.count == 1 && host.recoveryPresented)
            #expect(host.track.routeToken == token && host.track.sheet?.id == projectID)
            #expect(!host.acceptingMutations)
            host.requestAutoReviewIfNeeded()
            host.requestAutoReviewIfNeeded()
            #expect(presented.count == 1 && opens == 0)
            #expect(host.beginQuit() == nil)
            let pending = try #require(track.workspace.snapshot?.pendingSleepInterval)
            let preview = try SleepPlanner.skip(pending, in: try #require(track.workspace.snapshot))
            let submission = try #require(presented[0].submit(.skip(preview)))
            await submission.value
            await host.drain()
            #expect(track.workspace.snapshot?.pendingSleepInterval == nil)
            #expect(!host.recoveryPresented && host.acceptingMutations)
            #expect(host.track.routeToken == token && host.track.sheet?.id == projectID)
            // Skip may delete the sole open zero-duration entry; keep fixture teardown readable.
            if track.workspace.availability == .closed { try await track.workspace.open() }
        }
    }

    @Test(arguments: [false, true])
    func unlockingReviewsOneIntervalFromLockToUnlock(alsoSleeps: Bool) async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            defer { host.invalidate() }
            let clock = NativeClock()
            let lifecycle = Lifecycle(host: host)
            track.workspace.configureTimer(clock: { clock.read() })
            let projectID = try await project(track)
            let leaf = try await task(track, project: projectID)
            var presented: [TimeReviewController] = []
            host.recoveryPresentationHandler = { presented.append($0) }
            host.installSceneActions(workspace: {}, settings: {})
            host.submitTimer(.start(taskID: leaf))
            await host.drain()

            clock.set(110)
            lifecycle.willSleep(.screenLock)
            clock.set(120)
            lifecycle.willSleep(.screenLock)  // Duplicate lock does not move the start.
            if alsoSleeps { lifecycle.willSleep() }
            clock.set(130)
            lifecycle.didWake(at: Date(timeIntervalSince1970: 130))
            await host.drain()
            #expect(lifecycle.sleeping && presented.isEmpty)
            #expect(track.workspace.snapshot?.pendingSleepInterval?.wakeAt == nil)

            clock.set(140)
            lifecycle.didWake(at: Date(timeIntervalSince1970: 140), .screenLock)
            lifecycle.didWake(at: Date(timeIntervalSince1970: 141), .screenLock)
            await host.drain()
            let snapshot = try #require(track.workspace.snapshot)
            let interval = try #require(snapshot.pendingSleepInterval)
            let active = try #require(snapshot.activeTimer)
            #expect(presented.count == 1)
            #expect(!lifecycle.sleeping && !host.acceptingMutations)
            #expect(interval.taskID == leaf && interval.sleepAt == 110 && interval.wakeAt == 140)
            #expect(active.checkpointAt == 140)
            #expect(snapshot.entries.filter { $0.endAt != nil }.map(\.endAt) == [110])

            let preview = try SleepPlanner.include(interval, endAt: nil, in: snapshot)
            let controller = try #require(presented.first)
            await controller.submit(.include(preview))?.value
            let resolved = try #require(track.workspace.snapshot)
            #expect(resolved.entries.contains { $0.taskID == leaf && $0.startAt == 110 && $0.endAt == 140 })
            #expect(resolved.activeTimer == active && resolved.pendingSleepInterval == nil)
            #expect(!host.recoveryPresented && host.acceptingMutations)
        }
    }

    @Test func anotherLockDuringReviewLeavesExistingIntervalAndRequiresExplicitTimerEnd() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            defer { host.invalidate() }
            let clock = NativeClock()
            let lifecycle = Lifecycle(host: host)
            track.workspace.configureTimer(clock: { clock.read() })
            let projectID = try await project(track)
            let leaf = try await task(track, project: projectID)
            host.recoveryPresentationHandler = { _ in }
            host.installSceneActions(workspace: {}, settings: {})
            host.submitTimer(.start(taskID: leaf))
            await host.drain()
            clock.set(110)
            lifecycle.willSleep()
            lifecycle.didWake(at: Date(timeIntervalSince1970: 120))
            await host.drain()
            let saved = try #require(track.workspace.snapshot)
            let controller = try #require(host.recoveryController)

            clock.set(130)
            lifecycle.willSleep(.screenLock)
            clock.set(140)
            lifecycle.didWake(at: Date(timeIntervalSince1970: 140), .screenLock)
            await host.drain()
            #expect(host.recoveryController === controller)
            #expect(track.workspace.snapshot == saved)
            #expect(track.workspace.timerStatus == .reviewRequired)

            let resolved = try SleepPlanner.interruption(endAt: nil, in: saved)
            await controller.submit(.resolveInterruption(resolved))?.value
            let pending = try #require(track.workspace.snapshot?.pendingSleepInterval)
            #expect(pending == saved.pendingSleepInterval && track.workspace.snapshot?.activeTimer == nil)
            let nextController = try #require(host.recoveryController)
            #expect(nextController !== controller)
            let skipped = try SleepPlanner.skip(pending, in: try #require(track.workspace.snapshot))
            await nextController.submit(.skip(skipped))?.value
            #expect(!host.recoveryPresented && host.acceptingMutations)
        }
    }

    @Test(arguments: ["Review Save & Stop", "Review explicit discard"])
    func interruptedPanelShowsReviewChoices(action: String) async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            defer {
                host.recoveryPanel?.close()
                host.invalidate()
            }
            let clock = NativeClock()
            track.workspace.configureTimer(clock: { clock.read() })
            let projectID = try await project(track)
            let leaf = try await task(track, project: projectID)
            host.submitTimer(.start(taskID: leaf))
            await host.drain()
            host.installSceneActions(workspace: {}, settings: {})
            clock.set(110)
            _ = try await track.workspace.enqueueTimer(.checkpoint).value
            await track.workspace.close()
            try await track.workspace.open()
            clock.set(170)
            await host.drain()
            let panel = try #require(host.recoveryPanel)
            try #require(panel.contentViewController).view.layoutSubtreeIfNeeded()
            #expect(panel.frame.height >= 600)
            var buttons: [NSButton] = []
            func inspect(_ view: NSView) {
                if let button = view as? NSButton, !button.isHidden { buttons.append(button) }
                view.subviews.forEach(inspect)
            }
            inspect(try #require(panel.contentView))
            #expect(buttons.contains { $0.title == "Review Save & Stop" })
            #expect(buttons.contains { $0.title == "Review explicit discard" })
            try #require(buttons.first { $0.title == action }).performClick(nil)
            inspect(try #require(panel.contentView))
            #expect(!buttons.contains { $0.title == "Confirm reviewed action" && $0.isHidden })
            try #require(buttons.first { $0.title == "Confirm reviewed action" }).performClick(nil)
            await host.drain()
            #expect(host.recoveryPanel == nil)
            #expect(track.workspace.snapshot?.pendingSleepInterval == nil)
            #expect(track.workspace.snapshot?.activeTimer == nil)
            if action == "Review Save & Stop" {
                #expect(track.workspace.snapshot?.entries.contains { $0.endAt == 110 } == true)
            } else {
                #expect(track.workspace.snapshot?.entries.isEmpty == true)
            }
        }
    }

    @Test func knownGapPanelShowsTimeAndChoices() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            defer { host.invalidate() }
            let clock = NativeClock()
            let lifecycle = Lifecycle(host: host)
            track.workspace.configureTimer(clock: { clock.read() })
            let projectID = try await project(track)
            let leaf = try await task(track, project: projectID)
            host.submitTimer(.start(taskID: leaf))
            await host.drain()
            host.installSceneActions(workspace: {}, settings: {})
            clock.set(110)
            lifecycle.willSleep()
            await host.drain()
            lifecycle.didWake(at: Date(timeIntervalSince1970: 170))
            await host.drain()
            let panel = try #require(host.recoveryPanel)
            try #require(panel.contentViewController).view.layoutSubtreeIfNeeded()
            #expect(panel.frame.height >= 300)
            var labels: [NSTextField] = []
            var buttons: [NSButton] = []
            func inspect(_ view: NSView) {
                if let label = view as? NSTextField { labels.append(label) }
                if let button = view as? NSButton { buttons.append(button) }
                view.subviews.forEach(inspect)
            }
            inspect(try #require(panel.contentView))
            #expect(labels.contains { $0.stringValue.contains("Time away:") })
            #expect(labels.contains { $0.stringValue.contains("Task:") })
            #expect(buttons.contains { $0.title == "Track Time" })
            #expect(buttons.contains { $0.title == "Don’t Track" })
            clock.set(180)
            let controller = try #require(host.recoveryController)
            let snapshot = try #require(track.workspace.snapshot)
            let preview = try SleepPlanner.include(snapshot.pendingSleepInterval!, endAt: nil, in: snapshot)
            await controller.submit(.include(preview))?.value
            await host.drain()
            #expect(controller.error == nil)
            #expect(track.workspace.snapshot?.pendingSleepInterval == nil)
            #expect(!host.recoveryPresented)
        }
    }

    @Test func recoveryDoesNotReplaceSuspendedTaskDraft() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            defer { host.invalidate() }
            let clock = NativeClock()
            let lifecycle = Lifecycle(host: host)
            track.workspace.configureTimer(clock: { clock.read() })
            let projectID = try await project(track)
            let root = try await task(track, project: projectID, name: "Root")
            let leaf = try await task(track, project: projectID, parent: root, name: "Leaf")
            host.submitTimer(.start(taskID: leaf))
            await host.drain()
            host.track.newTask(projectID: projectID, parentID: root)
            host.track.editConstrainingBudget(taskID: root)
            let suspended = host.track.suspendedTaskDraft
            host.recoveryPresentationHandler = { _ in }
            host.installSceneActions(workspace: {}, settings: {})
            clock.set(110)
            lifecycle.willSleep()
            await host.drain()
            lifecycle.didWake(at: Date(timeIntervalSince1970: 120))
            await host.drain()
            #expect(host.recoveryPresented)
            #expect(host.track.suspendedTaskDraft?.name == suspended?.name)
            #expect(host.track.sheet?.id == root)
        }
    }

    @Test func recoveryCoalescesAcrossReopenAndUnavailableSnapshot() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            defer { host.invalidate() }
            let clock = NativeClock()
            let lifecycle = Lifecycle(host: host)
            track.workspace.configureTimer(clock: { clock.read() })
            let projectID = try await project(track)
            let leaf = try await task(track, project: projectID)
            host.submitTimer(.start(taskID: leaf))
            await host.drain()
            var presented: [TimeReviewController] = []
            host.recoveryPresentationHandler = { presented.append($0) }
            host.installSceneActions(workspace: {}, settings: {})
            clock.set(110)
            lifecycle.willSleep()
            await host.drain()
            lifecycle.didWake(at: Date(timeIntervalSince1970: 120))
            await host.drain()
            #expect(presented.count == 1)
            await track.workspace.close()
            host.requestAutoReviewIfNeeded()
            #expect(presented.count == 1 && host.recoveryPresented)
            host.reopen()
            await host.drain()
            #expect(presented.count == 1 && host.recoveryPresented)
        }
    }

    @Test func informationUsesOneShotSinkAndFailuresStayInApp() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            defer { host.invalidate() }
            var messages: [String] = []
            var ids: [UUID] = []
            host.information = {
                ids.append($0)
                messages.append($1)
            }
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
        var delivered: [UNNotificationRequest] = []
        var prompts = 0
        let notice = BudgetNotifications(
            path: { _ in "Task" }, reveal: { _ in },
            authorizationStatus: { .authorized },
            requestAuthorization: {
                prompts += 1
                return true
            },
            deliver: { delivered.append($0) })
        let id = UUID()
        let taskID = UUID()
        notice.notify(id: id, title: "Created", body: "Moved entries", taskIDs: [taskID])
        notice.notify(id: id, title: "Created", body: "Moved entries", taskIDs: [taskID])
        await notice.waitForPendingDelivery()
        #expect(delivered.count == 1 && prompts == 0)
        #expect(delivered[0].content.sound != nil)
        #expect(BudgetNotifications.taskIDs(in: delivered[0].content.userInfo) == [taskID])
        var attempts = 0
        let denied = BudgetNotifications(
            path: { _ in "Task" }, reveal: { _ in },
            authorizationStatus: { .denied },
            requestAuthorization: {
                prompts += 1
                return true
            },
            deliver: { _ in attempts += 1 })
        denied.notify(id: UUID(), title: "Created", body: "Task created")
        await denied.waitForPendingDelivery()
        #expect(attempts == 0 && prompts == 0)
        let failing = BudgetNotifications(
            path: { _ in "Task" }, reveal: { _ in },
            authorizationStatus: { .authorized },
            requestAuthorization: {
                prompts += 1
                return true
            },
            deliver: { _ in
                attempts += 1
                throw LibraryAccessError.unavailable
            })
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
                let notices = BudgetNotifications(
                    path: { _ in "Task" }, reveal: { _ in },
                    authorizationStatus: { status }, requestAuthorization: { false },
                    deliver: { _ in
                        attempts += 1
                        throw LibraryAccessError.unavailable
                    })
                let baseline = BudgetWarningBatch(
                    id: UUID(),
                    warnings: [
                        BudgetWarning(taskID: taskID, threshold: .eighty)
                    ])
                var outstanding = [baseline]
                notices.consume(
                    snapshot: snapshot, batches: outstanding,
                    acknowledge: { id in outstanding.removeAll { $0.id == id } })
                #expect(outstanding.isEmpty && attempts == 0)
                let fresh = BudgetWarningBatch(id: UUID(), warnings: baseline.warnings)
                outstanding = [fresh]
                notices.consume(
                    snapshot: snapshot, batches: outstanding,
                    acknowledge: { id in outstanding.removeAll { $0.id == id } })
                #expect(outstanding.isEmpty && attempts == 0)
                await notices.waitForPendingDelivery()
                #expect(attempts == (status == .authorized ? 1 : 0))
                notices.consume(snapshot: snapshot, batches: [fresh])
                await notices.waitForPendingDelivery()
                #expect(attempts == (status == .authorized ? 1 : 0))
                outstanding = [fresh]
                notices.consume(
                    snapshot: nil, batches: outstanding,
                    acknowledge: { id in outstanding.removeAll { $0.id == id } })
                #expect(outstanding.isEmpty)
            }
        }
    }
}

extension NativeHostTests {
    @Test func confirmedOpenCannotClearUncertaintyAcrossAcceptedClose() async throws {
        let directory = fixtureTemporaryDirectory().appendingPathComponent(
            "RecoveryClosing.\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "NativeRecovery.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = NativeRecoveryProbe(openError: LibraryAccessError.publicationIndeterminate)
        let openingGate = NativeSubmissionGate()
        let closingGate = NativeSubmissionGate()
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
        host.reopen()
        await host.drain()
        #expect(workspace.availability == .blocked && workspace.snapshot == nil)
        #expect(workspace.publicationUncertain && host.hasUncertainPublication)
        await probe.setOpenError(nil)
        let opening = workspace.enqueueOpen()
        let openingCompletion = Task { @MainActor in
            do { try await opening.value } catch {
                // Surface setup failures even when open never reaches the settings gate.
                await openingGate.pause()
                throw error
            }
        }
        await openingGate.waitForArrival()
        let closing = workspace.enqueueClose()  // Accepted while the real open is suspended.
        #expect(workspace.availability == .closing && !host.canReopen)
        await openingGate.release()
        try await openingCompletion.value
        await closingGate.waitForArrival()  // Keep confirmed open rows visible while close is in flight.
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
    func failedConflictRefreshIsStaleAndIssueFreeReviewStillHasFeedback(
        refreshError: LibraryAccessError
    ) async throws {
        let directory = fixtureTemporaryDirectory().appendingPathComponent(
            "RecoveryActual.\(UUID())", isDirectory: true)
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
        host.reopen()
        await host.drain()
        let projectID = try await project(host.track)
        let id = try await task(host.track, project: projectID)
        workspace.configureTimer(clock: { 100 })
        host.submitTimer(.start(taskID: id))
        await host.drain()
        let before = try #require(workspace.snapshot)
        await probe.setFailSnapshot(true, error: refreshError)
        workspace.configureTimer(
            clock: { 110 },
            write: { _, _, revision, _, _ in
                throw StorageError.revisionConflict(expected: revision, actual: revision + 1)
            })
        let conflict = StorageError.revisionConflict(
            expected: before.revision, actual: before.revision + 1)
        await #expect(throws: conflict) { try await workspace.enqueueTimer(.checkpoint).value }
        #expect(workspace.availability == .blocked)
        #expect(
            workspace.issue == (refreshError == .publicationIndeterminate ? .uncertainSave : .unavailable)
        )
        verifyConflictRefreshFeedback(
            host: host, workspace: workspace, before: before, error: refreshError)
        await probe.setFailSnapshot(false)
        host.reopen()
        await host.drain()
        #expect(workspace.availability == .reviewRequired && workspace.issue == nil)
        #expect(host.available && !host.canReopen)
        verifyIssueFreeReviewFeedback(host: host, workspace: workspace)
        let counts = await probe.counts()
        #expect(counts.opens == 2 && counts.writes == 0)
        await workspace.close()
    }

    private func verifyConflictRefreshFeedback(
        host: NativeHost, workspace: WorkspaceModel, before: LibrarySnapshot,
        error: LibraryAccessError
    ) {
        #expect(workspace.snapshot == before && host.hasRecoveryFeedback)
        #expect(workspace.publicationUncertain == (error == .publicationIndeterminate))
        #expect(host.hasUncertainPublication == (error == .publicationIndeterminate))
        if error == .publicationIndeterminate {
            #expect(host.recoveryMessage.contains("Do not repeat it"))
        } else {
            #expect(host.recoveryMessage.contains("reopen and inspect"))
        }
        #expect(!host.recoveryMessage.contains("current rows"))
    }

    private func verifyIssueFreeReviewFeedback(host: NativeHost, workspace: WorkspaceModel) {
        #expect(!workspace.publicationUncertain && !host.hasUncertainPublication)
        #expect(host.track.failure == nil && host.reopenFailure == nil)
        #expect(host.hasRecoveryFeedback)  // Real helper must expose Review time even with no issue/error.
        #expect(host.recoveryMessage.contains("Resolve interrupted time"))
        #expect(host.recoveryMessage.contains("unbilled"))
    }
}
