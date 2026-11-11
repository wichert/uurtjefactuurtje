import AppKit
import Foundation
import Testing

@testable import LibraryStore
@testable import UurtjeFactuurtje

extension MenuBarStatusTests {
  @Test func nativeMenuItemsSearchAndTaskSwitching() async throws {
    try await withTrack { track, directory in
      let suite = "MenuLayoutTests.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let host = NativeHost(directory: directory, workspace: track.workspace, defaults: defaults)
      defer { host.invalidate() }
      let clock = NativeClock()
      track.workspace.configureTimer(clock: { clock.read() })
      let projectA = try await project(track, name: "Project A")
      let meetings = try await task(track, project: projectA, name: "Meetings")
      let feat1 = try await task(track, project: projectA, name: "Feat 1")
      let feat2 = try await task(track, project: projectA, name: "Feat 2")

      for (index, id) in [feat2, feat1].enumerated() {
        clock.set(100 + Int64(index * 10))
        _ = try await track.workspace.enqueueTimer(.start(taskID: id)).value
        clock.set(105 + Int64(index * 10))
        _ = try await track.workspace.enqueueTimer(
          .stop(expectedEntryID: track.workspace.snapshot?.activeTimer?.entryID)
        ).value
      }

      clock.set(200)
      _ = try await track.workspace.enqueueTimer(.start(taskID: meetings)).value
      let controller = MenuBarController(host: host, install: false)
      defer { controller.invalidate() }

      controller.query = "feat"
      verifyFilteredMenuTitles(controller)

      // Starting Feat 1 while Meetings is running stops Meetings and starts Feat 1.
      clock.set(215)
      let startFeat1Item = try #require(
        controller.menu.items.first(where: { $0.title == "Start Project A / Feat 1" }))
      controller.startTask(startFeat1Item)
      await host.drain()

      let snapshot = try #require(track.workspace.snapshot)
      let active = try #require(snapshot.activeTimer)
      let activeEntry = try #require(snapshot.entries.first(where: { $0.id == active.entryID }))
      #expect(activeEntry.taskID == feat1)
      let stoppedMeetings = try #require(
        snapshot.entries.first(where: { $0.taskID == meetings && $0.startAt == 200 }))
      #expect(stoppedMeetings.endAt == 215)

      controller.query = ""
      verifyUpdatedMenuTitles(controller)

      clock.set(225)
      let stopItem = try #require(
        controller.menu.items.first(where: { $0.title == "Stop Project A / Feat 1" }))
      controller.stopTimer(stopItem)
      await host.drain()
      #expect(track.workspace.snapshot?.activeTimer == nil)
    }
  }

  @Test func menuRoutesPreserveDraftsAndSelectionDoesNotStart() async throws {
    try await withTrack { track, directory in
      let suite = "MenuRouteTests.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let host = NativeHost(directory: directory, workspace: track.workspace, defaults: defaults)
      defer { host.invalidate() }
      let projectID = try await project(track, name: "Project")
      let id = try await task(track, project: projectID, name: "Task")
      let before = try #require(track.workspace.snapshot)
      var opens = 0
      host.installSceneActions(workspace: { opens += 1 }, settings: {})
      host.track.selectedProjectID = projectID
      host.track.selectedTaskID = id
      #expect(WorkspaceMenu.matchingTasks(host.track, query: "Project / Task") == [id])
      host.revealNotificationTask(id)
      #expect(host.track.selectedTaskID == id)
      #expect(host.workspace.snapshot == before)
      #expect(host.workspace.snapshot?.activeTimer == nil)
      try verifyMenuRoutes(host: host, selectedTaskID: id)
      #expect(opens == 5)
      #expect(host.track.workspace === host.workspace)
      #expect(host.workspace === track.workspace)
      #expect(track.workspace.snapshot == before)
      #expect(track.workspace.snapshot?.activeTimer == nil)
      #expect(!track.workspace.isBusy)
    }
  }

  private func verifyFilteredMenuTitles(_ controller: MenuBarController) {
    let titles = controller.menu.items.map { item in
      item.isSeparatorItem ? "---" : (item.view != nil ? "[Search]" : item.title)
    }
    #expect(
      titles == [
        "Stop Project A / Meetings", "Start Project A / Feat 1", "Start Project A / Feat 2",
        "[Search]", "Start Project A / Feat 1", "Start Project A / Feat 2", "---",
        "Open main window", "Quit"
      ])
  }

  private func verifyUpdatedMenuTitles(_ controller: MenuBarController) {
    let updatedTitles = controller.menu.items.map { item in
      item.isSeparatorItem ? "---" : (item.view != nil ? "[Search]" : item.title)
    }
    #expect(
      updatedTitles == [
        "Stop Project A / Feat 1", "Start Project A / Meetings", "Start Project A / Feat 2",
        "[Search]", "---", "Open main window", "Quit"
      ])
  }

  private func verifyMenuRoutes(host: NativeHost, selectedTaskID: UUID) throws {
    host.newProject()
    guard case .project(let draft) = host.track.sheet else {
      Issue.record("Missing routed project draft")
      return
    }
    #expect(draft.isNew)
    let token = host.track.routeToken
    host.openReview()
    #expect(host.track.routeToken == token)
    #expect(host.track.sheet?.id == draft.id)
    #expect(host.track.feedback != nil)
    host.track.cancelSheet()
    host.addTime()
    guard case .correction(let route) = host.track.sheet else {
      Issue.record("Missing routed correction")
      return
    }
    guard case .add(let selected) = route.mode else {
      Issue.record("Expected add-time route")
      return
    }
    #expect(selected == selectedTaskID)
    host.track.cancelSheet()
    host.openReview()
    guard case .timeReview = host.track.sheet else {
      Issue.record("Missing routed time review")
      return
    }
  }
}
