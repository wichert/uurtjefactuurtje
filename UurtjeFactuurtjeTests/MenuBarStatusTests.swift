import AppKit
import Foundation
import Testing
@testable import LibraryStore
@testable import UurtjeFactuurtje

final class NativeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 100
    func read() -> Int64 { lock.withLock { value } }
    func set(_ value: Int64) { lock.withLock { self.value = value } }
}

private extension NSBitmapImageRep {
    func hasVisiblePixels() -> Bool {
        guard let data = bitmapData else { return false }
        let channels = samplesPerPixel
        for pixel in stride(from: 0, to: bytesPerRow * pixelsHigh, by: bytesPerRow) {
            for offset in stride(from: 0, to: pixelsWide * channels, by: channels) {
                if hasAlpha {
                    if data[pixel + offset + channels - 1] != 0 { return true }
                } else if (0..<(channels == 2 ? 1 : min(channels, 3))).contains(where: {
                    data[pixel + offset + $0] != 0
                }) { return true }
            }
        }
        return false
    }
}

@Suite @MainActor struct MenuBarStatusTests {
    @Test func customMenuIconRendersInStatusButton() throws {
        let status = MenuBarStatus(title: "", systemImage: "MenuIcon", accessibilityLabel: "Tracking stopped")
        let image = try #require(MenuBarController.image(for: status))
        #expect(image.size == NSSize(width: 22, height: 22))
        #expect(image.isTemplate)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 44, pixelsHigh: 44,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        #expect(bitmap.hasVisiblePixels())
    }
    @Test func elapsedBoundaries() {
        for (seconds, text): (Int64, String) in [(0, "00:00:00"), (59, "00:00:59"), (60, "00:01:00"),
            (3599, "00:59:59"), (3600, "01:00:00"), (86400, "24:00:00"), (360000, "100:00:00")] {
            #expect(MenuBarStatus.elapsed(seconds) == text)
        }
    }
    @Test func safeProjectionAndClosedWindowRefresh() async throws {
        try await withTrack { t, directory in
            let host = NativeHost(directory: directory, workspace: t.workspace)
            let clock = NativeClock()
            t.workspace.configureTimer(clock: { clock.read() })
            #expect(MenuBarStatus.project(host: host, at: Date(timeIntervalSince1970: 100)).accessibilityLabel == "Tracking stopped")
            let p = try await project(t, name: "First"), other = try await project(t, name: "Second")
            let id = try await task(t, project: p, name: "Duplicate")
            _ = try await task(t, project: other, name: "Duplicate")
            _ = try await t.workspace.enqueueTimer(.start(taskID: id)).value
            let controller = MenuBarController(host: host, install: false)
            let before = t.workspace.snapshot
            for seconds: Int64 in [0, 1, 59, 60, 3599, 3600, 86400] {
                clock.set(100 + seconds)
                controller.refresh(at: Date(timeIntervalSince1970: Double(100 + seconds)))
                #expect(controller.status.title == MenuBarStatus.elapsed(seconds))
                #expect(controller.status.accessibilityLabel.contains("First / Duplicate"))
            }
            #expect(t.workspace.snapshot == before) // Display samples cannot checkpoint.
            host.sleeping = true
            controller.refresh(at: Date())
            #expect(controller.status.systemImage == "moon.zzz")
            host.sleeping = false
            clock.set(99)
            controller.refresh(at: Date(timeIntervalSince1970: 99))
            #expect(controller.status.title.isEmpty)
            controller.refresh(at: Date(timeIntervalSince1970: .infinity))
            #expect(controller.status.title.isEmpty)
            await #expect(throws: TimerError.clockRollback) { try await t.workspace.enqueueTimer(.checkpoint).value }
            #expect(MenuBarStatus.project(host: host, at: Date()).accessibilityLabel.contains("paused"))
            await t.workspace.close()
            #expect(MenuBarStatus.project(host: host, at: Date()).accessibilityLabel.contains("unavailable"))
            try await t.workspace.open()
            #expect(MenuBarStatus.project(host: host, at: Date()).accessibilityLabel == "Time needs review")
            controller.invalidate(); host.invalidate()
        }
    }

    @Test func runningWithPendingCountsKeepsElapsedTitleAndDoesNotWrite() async throws {
        try await withTrack { t, directory in
            let suite = "MenuPendingTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let host = NativeHost(directory: directory, workspace: t.workspace, defaults: defaults)
            defer { host.invalidate() }
            let lifecycle = Lifecycle(host: host)
            let clock = NativeClock()
            t.workspace.configureTimer(clock: { clock.read() })
            #expect(host.workspace === t.workspace)
            #expect(host.track.workspace === host.workspace)
            #expect(lifecycle.host === host)
            let p = try await project(t, name: "First")
            let id = try await task(t, project: p, name: "Work")
            _ = try await t.workspace.enqueueTimer(.start(taskID: id)).value
            clock.set(107)
            let baseline = MenuBarStatus.project(host: host, at: Date(timeIntervalSince1970: 107))
            #expect(baseline.title == "00:00:07")
            #expect(!baseline.accessibilityLabel.contains("pending"))
            let controller = MenuBarController(host: host, install: false)
            defer { controller.invalidate() }
            for count in 1...2 {
                let sleepAt: Int64 = 100 + Int64(count) * 100
                let wakeAt = sleepAt + 10
                clock.set(sleepAt)
                lifecycle.willSleep()
                await host.drain()
                lifecycle.didWake(at: Date(timeIntervalSince1970: Double(wakeAt)))
                await host.drain()
                let before = try #require(t.workspace.snapshot)
                let active = try #require(before.activeTimer)
                #expect(before.pendingSleepIntervals.count == count)
                #expect(before.pendingSleepIntervals.allSatisfy { $0.wakeAt != nil })
                #expect(t.workspace.timerStatus == .running(entryID: active.entryID))
                clock.set(wakeAt + 7)
                let warnings = t.workspace.budgetWarnings.map(\.id)
                for _ in 0..<3 {
                    controller.refresh(at: Date(timeIntervalSince1970: Double(wakeAt + 7)))
                    #expect(controller.status.title == baseline.title)
                    #expect(controller.status.systemImage == baseline.systemImage)
                    #expect(controller.status.accessibilityLabel.contains("Tracking First / Work"))
                    #expect(controller.status.accessibilityLabel.contains("\(count) pending sleep interval(s) need review — unbilled"))
                }
                #expect(t.workspace.snapshot == before)
                #expect(t.workspace.budgetWarnings.map(\.id) == warnings)
                _ = try await t.workspace.enqueueTimer(.stop(expectedEntryID: active.entryID)).value
                let idle = try #require(t.workspace.snapshot)
                controller.refresh(at: Date(timeIntervalSince1970: Double(wakeAt + 7)))
                #expect(controller.status.title.isEmpty)
                #expect(controller.status.accessibilityLabel.contains("Time needs review"))
                #expect(controller.status.accessibilityLabel.contains("\(count) pending sleep interval(s)"))
                #expect(t.workspace.snapshot == idle)
                if count == 1 {
                    clock.set(wakeAt + 8)
                    _ = try await t.workspace.enqueueTimer(.start(taskID: id)).value
                }
            }
        }
    }

    @Test func nativeMenuItemsSearchAndTaskSwitching() async throws {
        try await withTrack { t, directory in
            let suite = "MenuLayoutTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let host = NativeHost(directory: directory, workspace: t.workspace, defaults: defaults)
            defer { host.invalidate() }
            let clock = NativeClock()
            t.workspace.configureTimer(clock: { clock.read() })
            let projectA = try await project(t, name: "Project A")
            let meetings = try await task(t, project: projectA, name: "Meetings")
            let feat1 = try await task(t, project: projectA, name: "Feat 1")
            let feat2 = try await task(t, project: projectA, name: "Feat 2")

            for (index, id) in [feat2, feat1].enumerated() {
                clock.set(100 + Int64(index * 10))
                _ = try await t.workspace.enqueueTimer(.start(taskID: id)).value
                clock.set(105 + Int64(index * 10))
                _ = try await t.workspace.enqueueTimer(.stop(expectedEntryID: t.workspace.snapshot?.activeTimer?.entryID)).value
            }

            clock.set(200)
            _ = try await t.workspace.enqueueTimer(.start(taskID: meetings)).value
            let controller = MenuBarController(host: host, install: false)
            defer { controller.invalidate() }

            controller.query = "feat"
            let titles = controller.menu.items.map { item in
                item.isSeparatorItem ? "---" : (item.view != nil ? "[Search]" : item.title)
            }
            #expect(titles == [
                "Stop Project A / Meetings",
                "Start Project A / Feat 1",
                "Start Project A / Feat 2",
                "[Search]",
                "Start Project A / Feat 1",
                "Start Project A / Feat 2",
                "---",
                "Open main window",
                "Quit"
            ])

            // Starting Feat 1 while Meetings is running stops Meetings and starts Feat 1.
            clock.set(215)
            let startFeat1Item = try #require(controller.menu.items.first(where: { $0.title == "Start Project A / Feat 1" }))
            controller.startTask(startFeat1Item)
            await host.drain()

            let snapshot = try #require(t.workspace.snapshot)
            let active = try #require(snapshot.activeTimer)
            let activeEntry = try #require(snapshot.entries.first(where: { $0.id == active.entryID }))
            #expect(activeEntry.taskID == feat1)
            let stoppedMeetings = try #require(snapshot.entries.first(where: { $0.taskID == meetings && $0.startAt == 200 }))
            #expect(stoppedMeetings.endAt == 215)

            controller.query = ""
            let updatedTitles = controller.menu.items.map { item in
                item.isSeparatorItem ? "---" : (item.view != nil ? "[Search]" : item.title)
            }
            #expect(updatedTitles == [
                "Stop Project A / Feat 1",
                "Start Project A / Meetings",
                "Start Project A / Feat 2",
                "[Search]",
                "---",
                "Open main window",
                "Quit"
            ])

            clock.set(225)
            let stopItem = try #require(controller.menu.items.first(where: { $0.title == "Stop Project A / Feat 1" }))
            controller.stopTimer(stopItem)
            await host.drain()
            #expect(t.workspace.snapshot?.activeTimer == nil)
        }
    }

    @Test func menuRoutesPreserveDraftsAndSelectionDoesNotStart() async throws {
        try await withTrack { t, directory in
            let suite = "MenuRouteTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let host = NativeHost(directory: directory, workspace: t.workspace, defaults: defaults)
            defer { host.invalidate() }
            let p = try await project(t, name: "Project")
            let id = try await task(t, project: p, name: "Task")
            let before = try #require(t.workspace.snapshot)
            var opens = 0
            host.installSceneActions(workspace: { opens += 1 }, settings: {})
            host.track.selectedProjectID = p
            host.track.selectedTaskID = id
            #expect(WorkspaceMenu.matchingTasks(host.track, query: "Project / Task") == [id])
            host.revealNotificationTask(id)
            #expect(host.track.selectedTaskID == id)
            #expect(host.workspace.snapshot == before)
            #expect(host.workspace.snapshot?.activeTimer == nil)
            host.newProject()
            guard case .project(let draft) = host.track.sheet else {
                Issue.record("Missing routed project draft"); return
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
                Issue.record("Missing routed correction"); return
            }
            guard case .add(let selected) = route.mode else {
                Issue.record("Expected add-time route"); return
            }
            #expect(selected == id)
            host.track.cancelSheet()
            host.openReview()
            guard case .timeReview = host.track.sheet else {
                Issue.record("Missing routed time review"); return
            }
            #expect(opens == 5)
            #expect(host.track.workspace === host.workspace)
            #expect(host.workspace === t.workspace)
            #expect(t.workspace.snapshot == before)
            #expect(t.workspace.snapshot?.activeTimer == nil)
            #expect(!t.workspace.isBusy)
        }
    }
}
