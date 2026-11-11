import AppKit
import Foundation
import Testing
@testable import LibraryStore
@testable import UurtjeFactuurtje


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


}
