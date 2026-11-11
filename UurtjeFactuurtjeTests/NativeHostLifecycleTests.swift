import AppKit
import Foundation
import SwiftUI
import Testing
import UserNotifications

@testable import LibraryStore
@testable import UurtjeFactuurtje

@MainActor struct DeferredWakeAndNoticeTests {
  @Test func wakeIntentDefersCoalescesAndResumesAfterDraftAndQuit() async throws {
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
      let quit = try #require(host.beginQuit())
      clock.set(110)
      lifecycle.willSleep()
      await host.drain()
      lifecycle.didWake(at: Date(timeIntervalSince1970: 120))
      await host.drain()
      #expect(track.workspace.snapshot?.pendingSleepIntervals.count == 1)
      #expect(host.pendingAutoReview && host.track.routeToken == token)
      host.requestAutoReviewIfNeeded()
      host.requestAutoReviewIfNeeded()
      var opens = 0
      host.installSceneActions(
        workspace: {
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
      guard case .timeReview = host.track.sheet else {
        Issue.record("Missing automatic review")
        return
      }
      #expect(track.workspace.snapshot == before)
      host.requestAutoReviewIfNeeded()
      #expect(opens == 1 && !host.pendingAutoReview)
    }
  }

  @Test func cancellingFinalSuspendedDraftAutomaticallyRetriesReview() async throws {
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
      var opens = 0
      host.installSceneActions(workspace: { opens += 1 }, settings: {})
      clock.set(110)
      lifecycle.willSleep()
      await host.drain()
      lifecycle.didWake(at: Date(timeIntervalSince1970: 120))
      await host.drain()
      #expect(host.pendingAutoReview && opens == 0)
      host.track.cancelSheet()
      #expect(host.track.suspendedTaskDraft == nil && host.track.sheet != nil)
      host.track.cancelSheet()
      // Match the host'seconds observation callback without first timer or polling loop.
      await Task { @MainActor in }.value
      #expect(opens == 1 && !host.pendingAutoReview)
      guard case .timeReview = host.track.sheet else {
        Issue.record("Missing deferred review")
        return
      }
    }
  }

  @Test func acceptedWorkAndUnavailableLibraryKeepAutomaticIntent() async throws {
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
      #expect(host.track.begin(token))
      clock.set(110)
      lifecycle.willSleep()
      await host.drain()
      lifecycle.didWake(at: Date(timeIntervalSince1970: 120))
      await host.drain()
      var opens = 0
      host.installSceneActions(workspace: { opens += 1 }, settings: {})
      #expect(host.pendingAutoReview && opens == 0 && host.track.acceptedWork)
      await track.workspace.close()
      host.track.complete(token)
      host.requestAutoReviewIfNeeded()
      #expect(opens == 0 && host.pendingAutoReview)
      host.reopen()
      await host.drain()
      #expect(opens == 1 && !host.pendingAutoReview)
      guard case .timeReview = host.track.sheet else {
        Issue.record("Missing reopened review")
        return
      }
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
    #expect(host.recoveryMessage.contains("Time needs review"))
    #expect(host.recoveryMessage.contains("unbilled"))
  }
}
