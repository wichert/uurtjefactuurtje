import AppKit
import Foundation
import SwiftUI
import Testing
import UserNotifications

@testable import LibraryStore
@testable import UurtjeFactuurtje

extension NativeHostTests {
  @Test func soleOwnerPendingRoutesAndDrafts() async throws {
    try await withTrack { track, directory in
      let host = NativeHost(directory: directory, workspace: track.workspace)
      #expect(host.track.workspace === host.workspace)
      #expect(host.workspace === track.workspace)
      let projectID = try await project(track)
      let root = try await task(track, project: projectID, name: "Parent")
      let leaf = try await task(track, project: projectID, parent: root, name: "Leaf")
      var opens = 0
      var settings = 0
      host.revealNotificationTask(leaf)
      host.openReports()
      host.openSettings()
      #expect(opens == 0)
      host.installSceneActions(workspace: { opens += 1 }, settings: { settings += 1 })
      #expect(opens == 2)
      #expect(settings == 1)
      #expect(host.track.destination == .reports)
      #expect(host.track.selectedTaskID == leaf)
      host.newTask()
      let token = host.track.routeToken
      host.newProject()
      host.addTime()
      host.openReview()
      host.revealNotificationTask(leaf)
      #expect(host.track.routeToken == token)
      #expect(host.track.sheet != nil)
      #expect(host.track.feedback != nil)
      #expect(WorkspaceMenu.matchingTasks(host.track, query: "Parent") == [leaf])
      #expect(!WorkspaceMenu.recentTasks(host.track).contains(root))
      host.track.cancelSheet()
      host.submitTimer(.start(taskID: leaf))
      await host.drain()
      #expect(WorkspaceMenu.stopTitle(host.track) == "Stop Project / Parent / Leaf")
      #expect(WorkspaceMenu.recentTasks(host.track).isEmpty)
      host.submitTimer(.stop(expectedEntryID: track.workspace.snapshot?.activeTimer?.entryID))
      await host.drain()
      #expect(WorkspaceMenu.recentTasks(host.track) == [leaf])

      try await verifyRecentTaskRouting(track: track, host: host, leaf: leaf)
    }
  }

  @Test(arguments: [false, true])
  func reviewRouteSurvivesSceneActionReinstallation(afterSleep: Bool) async throws {
    try await withTrack { track, directory in
      let host = NativeHost(directory: directory, workspace: track.workspace)
      defer { host.invalidate() }
      if afterSleep {
        let clock = NativeClock()
        let lifecycle = Lifecycle(host: host)
        track.workspace.configureTimer(clock: { clock.read() })
        let projectID = try await project(track)
        let id = try await task(track, project: projectID)
        host.submitTimer(.start(taskID: id))
        await host.drain()
        clock.set(110)
        lifecycle.willSleep()
        await host.drain()
        lifecycle.didWake(at: Date(timeIntervalSince1970: 120))
        await host.drain()
        #expect(track.workspace.snapshot?.pendingSleepIntervals.count == 1)
      }
      let before = track.workspace.snapshot
      var opens = 0
      host.installSceneActions(
        workspace: {
          opens += 1
          // Opening first window can synchronously re-evaluate NativeCommands.body.
          host.installSceneActions(workspace: { opens += 1 }, settings: {})
        }, settings: {})
      host.openReview()
      #expect(opens == 1)
      #expect(host.track.destination == .track)
      guard case .timeReview = host.track.sheet else {
        Issue.record("Missing time review")
        return
      }
      #expect(host.track.feedback == nil)
      #expect(track.workspace.snapshot == before)
      host.track.cancelSheet()
      host.openReports()
      #expect(opens == 2 && host.track.destination == .reports)
    }
  }

  @Test func reentrantSceneCallbacksPreserveRouteOrder() async throws {
    try await withTrack { track, directory in
      let host = NativeHost(directory: directory, workspace: track.workspace)
      defer { host.invalidate() }
      var events: [String] = []
      host.installSceneActions(
        workspace: {
          events.append("workspace")
          if events.count == 1 {
            host.openSettings()
            host.openReports()
          }
        },
        settings: {
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
    #expect(timer.timeInterval == 15)
    timer.invalidate()
    try await withTrack { track, directory in
      let host = NativeHost(directory: directory, workspace: track.workspace)
      let lifecycle = Lifecycle(host: host)
      let clock = NativeClock()
      track.workspace.configureTimer(clock: { clock.read() })
      let projectID = try await project(track)
      let id = try await task(track, project: projectID)
      host.submitTimer(.start(taskID: id))
      await host.drain()
      clock.set(110)
      lifecycle.willSleep()
      #expect(lifecycle.sleeping)
      #expect(
        track.workspace.timerStatus
          != .running(entryID: track.workspace.snapshot!.activeTimer!.entryID))
      await lifecycle.host.drain()
      #expect(track.workspace.snapshot?.pendingSleepIntervals.first?.sleepAt == 110)
      lifecycle.didWake(at: Date(timeIntervalSince1970: 120.99))
      await lifecycle.host.drain()
      #expect(track.workspace.snapshot?.pendingSleepIntervals.first?.wakeAt == 120)
      #expect(!lifecycle.sleeping)
      host.invalidate()
      lifecycle.host.invalidate()
    }
  }

  private func verifyRecentTaskRouting(track: TrackPresentation, host: NativeHost, leaf: UUID)
    async throws {
    let clock = NativeClock()
    // Sibling temp directory, not first subdirectory of the open library: the store
    // treats unknown artifacts inside its directory as unsafe on reopen.
    let recentDirectory = fixtureTemporaryDirectory().appendingPathComponent(
      UUID().uuidString, isDirectory: true)
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
      _ = try await model.enqueueTimer(.stop(expectedEntryID: model.snapshot?.activeTimer?.entryID))
        .value
    }
    #expect(WorkspaceMenu.recentTasks(recentTrack) == [child, newer])
    #expect(WorkspaceMenu.recentTasks(recentTrack, limit: 3) == [child, newer, older])
    #expect(!WorkspaceMenu.recentTasks(recentTrack, limit: 3).contains(parent))
    #expect(WorkspaceMenu.matchingTasks(recentTrack, query: "Project / Parent / Child") == [child])
    #expect(WorkspaceMenu.matchingTasks(recentTrack, query: "Parent") == [child])
    #expect(WorkspaceMenu.matchingTasks(recentTrack, query: "").isEmpty)
    await model.close()
    await track.workspace.close()
    host.revealNotificationTask(leaf)
    host.reopen()
    await host.drain()
    #expect(host.track.selectedTaskID == leaf)
    host.revealNotificationTask(UUID())
    #expect(host.track.failure?.contains("no longer exists") == true)
    host.invalidate()
  }

}
