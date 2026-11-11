import AppKit
import Foundation
import SwiftUI
import Testing
import UserNotifications

@testable import LibraryStore
@testable import UurtjeFactuurtje

extension NativeHostTests {
  private final class FailedCloseCounters: @unchecked Sendable {
    var closes = 0
    var replies = 0
  }

  private struct FailedCloseRun {
    let lifecycle: Lifecycle
    let host: NativeHost
    let track: TrackPresentation
    let clock: NativeClock
    let wakeDuringClose: Bool
  }

  private struct FailedCloseState {
    let closes: Int
    let replies: Int
    let before: LibrarySnapshot
    let wakeDuringClose: Bool
  }

  @Test func draftCancelKeepsSuspendedDraftRouteAndWindow() async throws {
    try await withTrack { track, directory in
      let host = NativeHost(directory: directory, workspace: track.workspace)
      let projectID = try await project(track)
      let root = try await task(track, project: projectID)
      host.track.newTask(projectID: projectID, parentID: root)
      guard case .task(var draft) = host.track.sheet else {
        Issue.record("Missing draft")
        return
      }
      draft.name = "Unsent child"
      host.track.updateTaskDraft(draft)
      host.track.editConstrainingBudget(taskID: root)
      let token = host.track.routeToken
      let sheet = host.track.sheet?.id
      let before = track.workspace.snapshot
      var opens = 0
      var closes = 0
      host.installSceneActions(workspace: { opens += 1 }, settings: {})
      let lifecycle = Lifecycle(host: host)
      lifecycle.confirmQuit = {
        #expect(!host.track.acceptedWork)
        return false
      }
      lifecycle.close = { _ in closes += 1 }
      await withCheckedContinuation { done in
        lifecycle.reply = { accepted in
          #expect(!accepted)
          done.resume()
        }
        lifecycle.requestQuit()
      }
      #expect(closes == 0 && opens == 0 && host.acceptingMutations)
      #expect(host.track.routeToken == token && host.track.sheet?.id == sheet)
      #expect(host.track.suspendedTaskDraft?.name == "Unsent child")
      #expect(track.workspace.snapshot == before)
      host.invalidate()
    }
  }

  @Test func failedOwnedStopRequiresAnotherExplicitQuitWithoutReplay() async throws {
    try await withTrack { track, directory in
      let host = NativeHost(directory: directory, workspace: track.workspace)
      let clock = NativeClock()
      track.workspace.configureTimer(clock: { clock.read() })
      let projectID = try await project(track)
      let id = try await task(track, project: projectID)
      host.submitTimer(.start(taskID: id))
      await host.drain()
      let before = track.workspace.snapshot
      let writes = NativeQuitWriteProbe()
      var closes = 0
      var confirms = 0
      track.workspace.configureTimer(
        clock: { 110 },
        write: { _, _, _, _, _ in
          writes.record()
          throw StorageError.injectedFailure
        })
      let lifecycle = Lifecycle(host: host)
      lifecycle.confirmQuit = {
        confirms += 1
        return true
      }
      lifecycle.close = { model in
        closes += 1
        await model.close()
      }
      await withCheckedContinuation { done in
        lifecycle.reply = { accepted in
          #expect(!accepted)
          done.resume()
        }
        lifecycle.requestQuit()
      }
      #expect(writes.count == 1 && closes == 0 && host.acceptingMutations)
      #expect(track.workspace.snapshot == before)
      #expect(host.track.failure?.contains("Stop was not confirmed") == true)
      await withCheckedContinuation { done in
        lifecycle.reply = { accepted in
          #expect(accepted)
          done.resume()
        }
        lifecycle.requestQuit()
      }
      #expect(confirms == 2 && writes.count == 1 && closes == 1)
      try await track.workspace.open()
      #expect(track.workspace.snapshot == before)  // Paused timer left for review, not checkpoint-stopped.
      host.invalidate()
    }
  }

  @Test func lateLifecycleWorkDuringCloseIsNotAcceptedOrReplayed() async throws {
    try await withTrack { track, directory in
      let host = NativeHost(directory: directory, workspace: track.workspace)
      let gate = NativeSubmissionGate()
      let lifecycle = Lifecycle(host: host)
      let before = track.workspace.snapshot
      var closes = 0
      var replies = 0
      lifecycle.close = { model in
        closes += 1
        await gate.pause()  // Close adapter suspended before even submitting workspace close.
        #expect(model.snapshot == before && !model.isBusy)
        await model.close()
      }
      await withCheckedContinuation { done in
        lifecycle.reply = { accepted in
          #expect(accepted)
          replies += 1
          done.resume()
        }
        lifecycle.requestQuit()
        Task { @MainActor in
          await gate.waitForArrival()
          lifecycle.willSleep()
          lifecycle.didWake(at: Date(timeIntervalSince1970: 120))
          lifecycle.checkpointTick()
          lifecycle.budgetTick()
          lifecycle.requestQuit()
          #expect(!host.workspace.isBusy && !host.acceptingMutations)
          await gate.release()
        }
      }
      #expect(closes == 1 && replies == 1)
      host.invalidate()
    }
  }

  @Test func sleepAcceptedDuringDrainIsReviewedBeforeConfirmation() async throws {
    try await withTrack { track, directory in
      let host = NativeHost(directory: directory, workspace: track.workspace)
      let clock = NativeClock()
      track.workspace.configureTimer(clock: { clock.read() })
      let projectID = try await project(track)
      let id = try await task(track, project: projectID)
      host.submitTimer(.start(taskID: id))
      await host.drain()
      let gate = NativeSubmissionGate()
      let lifecycle = Lifecycle(host: host)
      track.workspace.configureTimer(
        clock: { clock.read() },
        write: { library, command, revision, instant, entry in
          await gate.pause()
          return try await library.performTimer(
            command, expectedRevision: revision, instant: instant, newEntryID: entry)
        })
      clock.set(105)
      host.submitTimer(.checkpoint)
      await gate.waitForArrival()
      var closes = 0
      var replies = 0
      lifecycle.confirmQuit = {
        #expect(track.workspace.snapshot?.pendingSleepIntervals.first?.sleepAt == 110)
        #expect(track.workspace.snapshot?.pendingSleepIntervals.first?.wakeAt == nil)
        #expect(!track.workspace.isBusy)
        return false
      }
      lifecycle.close = { _ in closes += 1 }
      await withCheckedContinuation { done in
        lifecycle.reply = { accepted in
          #expect(!accepted)
          replies += 1
          done.resume()
        }
        lifecycle.requestQuit()
        clock.set(110)
        lifecycle.willSleep()
        Task { await gate.release() }
      }
      #expect(closes == 0 && replies == 1 && host.acceptingMutations)
      #expect(track.workspace.snapshot?.activeTimer == nil)
      #expect(track.workspace.snapshot?.pendingSleepIntervals.first?.wakeAt == nil)
      host.invalidate()
    }
  }

  @Test func restoredUnownedTimerClosesUnchanged() async throws {
    try await withTrack { track, directory in
      let host = NativeHost(directory: directory, workspace: track.workspace)
      let projectID = try await project(track)
      let id = try await task(track, project: projectID)
      host.submitTimer(.start(taskID: id))
      await host.drain()
      await track.workspace.close()
      try await track.workspace.open()
      let before = try #require(track.workspace.snapshot)
      #expect(before.activeTimer != nil && host.track.ownedStop == nil)
      let writes = NativeQuitWriteProbe()
      track.workspace.configureTimer(
        clock: { 999 },
        write: { _, _, _, _, _ in
          writes.record()
          throw StorageError.injectedFailure
        })
      let lifecycle = Lifecycle(host: host)
      lifecycle.confirmQuit = { true }
      lifecycle.close = { model in
        #expect(model.snapshot == before)
        await model.close()
      }
      await withCheckedContinuation { done in
        lifecycle.reply = { accepted in
          #expect(accepted)
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

  @Test(arguments: [false, true])
  func unsentDraftIsNotRemovedBeforeCloseOutcome(closeFails: Bool) async throws {
    try await withTrack { track, directory in
      let host = NativeHost(directory: directory, workspace: track.workspace)
      let projectID = try await project(track)
      host.track.editProject(projectID)
      let token = host.track.routeToken
      let before = track.workspace.snapshot
      let lifecycle = Lifecycle(host: host)
      lifecycle.confirmQuit = {
        #expect(!host.track.acceptedWork)
        return true
      }
      lifecycle.close = { model in
        #expect(host.track.sheet?.id == projectID && host.track.routeToken == token)
        #expect(model.snapshot == before)
        if closeFails { throw LibraryAccessError.unavailable }
        await model.close()
      }
      await withCheckedContinuation { done in
        lifecycle.reply = { accepted in
          #expect(accepted == !closeFails)
          done.resume()
        }
        lifecycle.requestQuit()
      }
      #expect(host.track.sheet?.id == projectID && host.track.routeToken == token)
      if closeFails {
        #expect(host.acceptingMutations && track.workspace.snapshot == before)
      } else {
        #expect(track.workspace.availability == .closed)
      }
      host.invalidate()
    }
  }

  @Test(arguments: [false, true])
  func failedCloseReconcilesPhysicalSleepWithoutReplay(wakeDuringClose: Bool) async throws {
    try await withTrack { track, directory in
      let host = NativeHost(directory: directory, workspace: track.workspace)
      let clock = NativeClock()
      let writes = NativeQuitWriteProbe()
      track.workspace.configureTimer(clock: { clock.read() })
      let projectID = try await project(track)
      let id = try await task(track, project: projectID)
      host.submitTimer(.start(taskID: id))
      await host.drain()
      clock.set(105)
      track.workspace.configureTimer(
        clock: { clock.read() },
        write: { _, _, _, _, _ in
          writes.record()
          throw StorageError.injectedFailure
        })
      host.submitTimer(.checkpoint)
      await host.drain()
      let before = try #require(track.workspace.snapshot)
      let active = try #require(before.activeTimer)
      #expect(track.workspace.timerStatus == .paused(entryID: active.entryID))
      let lifecycle = Lifecycle(host: host)
      host.installSceneActions(workspace: {}, settings: {})
      let counters = FailedCloseCounters()
      await runFailedClose(
        run: FailedCloseRun(
          lifecycle: lifecycle, host: host, track: track, clock: clock,
          wakeDuringClose: wakeDuringClose), counters: counters)
      verifyFailedCloseCounts(
        writes: writes, host: host, track: track,
        state: FailedCloseState(
          closes: counters.closes, replies: counters.replies, before: before, wakeDuringClose: wakeDuringClose))
      if !wakeDuringClose {
        #expect(throws: TimerError.reviewRequired) {
          try track.workspace.timerLifecycleGate.sample(clock: { 120 })
        }
        lifecycle.didWake(at: Date(timeIntervalSince1970: 120))
      }
      #expect(!lifecycle.sleeping && !host.sleeping)
      #expect(!track.workspace.timerLifecycleGate.state().sleeping)
      #expect(try track.workspace.timerLifecycleGate.sample(clock: { 120 }).instant == 120)
      await #expect(throws: TimerError.reviewRequired) {
        try await track.workspace.enqueueTimer(.checkpoint).value
      }
      try verifyFailedCloseReview(host: host, track: track, writes: writes, before: before)
      host.invalidate()
    }
  }

  private func runFailedClose(
    run: FailedCloseRun, counters: FailedCloseCounters
  ) async {
    let lifecycle = run.lifecycle
    let host = run.host
    let track = run.track
    let clock = run.clock
    let wakeDuringClose = run.wakeDuringClose
    let gate = NativeSubmissionGate()
    lifecycle.confirmQuit = { true }
    lifecycle.close = { _ in
      counters.closes += 1
      await gate.pause()
      throw LibraryAccessError.unavailable
    }
    await withCheckedContinuation { done in
      lifecycle.reply = { accepted in
        #expect(!accepted)
        counters.replies += 1
        done.resume()
      }
      lifecycle.requestQuit()
      Task { @MainActor in
        await gate.waitForArrival()
        clock.set(110)
        lifecycle.willSleep()
        if wakeDuringClose { lifecycle.didWake(at: Date(timeIntervalSince1970: 120)) }
        lifecycle.requestQuit()
        lifecycle.checkpointTick()
        lifecycle.budgetTick()
        #expect(!track.workspace.isBusy && !host.acceptingMutations)
        await gate.release()
      }
    }
  }

  private func verifyFailedCloseCounts(
    writes: NativeQuitWriteProbe, host: NativeHost, track: TrackPresentation,
    state: FailedCloseState
  ) {
    #expect(state.closes == 1 && state.replies == 1 && writes.count == 1)
    #expect(host.acceptingMutations && track.workspace.snapshot == state.before)
    #expect(host.track.ownedStop == nil)
    #expect(track.workspace.timerStatus == .reviewRequired)
    #expect(track.workspace.timerLifecycleGate.state().sleeping == !state.wakeDuringClose)
  }

  private func verifyFailedCloseReview(
    host: NativeHost, track: TrackPresentation, writes: NativeQuitWriteProbe,
    before: LibrarySnapshot
  ) throws {
    #expect(writes.count == 1 && track.workspace.snapshot == before)
    #expect(track.workspace.snapshot?.pendingSleepIntervals.isEmpty == true)
    #expect(track.workspace.timerStatus == .reviewRequired)
    guard case .timeReview = host.track.sheet else {
      Issue.record("Missing failed-close review")
      return
    }
    #expect(!host.pendingAutoReview && host.track.failure?.contains("Close failed") == true)
    #expect(writes.count == 1 && track.workspace.snapshot == before)
  }
}
