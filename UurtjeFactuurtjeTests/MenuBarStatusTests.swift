import AppKit
import Foundation
import Testing

@testable import LibraryStore
@testable import UurtjeFactuurtje

extension NSBitmapImageRep {
    fileprivate func hasVisiblePixels() -> Bool {
        guard let data = bitmapData else { return false }
        let channels = samplesPerPixel
        for pixel in stride(from: 0, to: bytesPerRow * pixelsHigh, by: bytesPerRow) {
            for offset in stride(from: 0, to: pixelsWide * channels, by: channels) {
                if hasAlpha {
                    if data[pixel + offset + channels - 1] != 0 { return true }
                } else if (0..<(channels == 2 ? 1 : min(channels, 3))).contains(where: {
                    data[pixel + offset + $0] != 0
                }) {
                    return true
                }
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
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 44, pixelsHigh: 44,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        #expect(bitmap.hasVisiblePixels())
    }
    @Test func elapsedBoundaries() {
        for (seconds, text): (Int64, String) in [
            (0, "00:00:00"), (59, "00:00:59"), (60, "00:01:00"),
            (3599, "00:59:59"), (3600, "01:00:00"), (86400, "24:00:00"), (360000, "100:00:00")
        ] {
            #expect(MenuBarStatus.elapsed(seconds) == text)
        }
    }
    @Test func safeProjectionAndClosedWindowRefresh() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            let clock = NativeClock()
            track.workspace.configureTimer(clock: { clock.read() })
            #expect(
                MenuBarStatus.project(host: host, at: Date(timeIntervalSince1970: 100)).accessibilityLabel
                    == "Tracking stopped")
            let projectID = try await project(track, name: "First")
            let other = try await project(track, name: "Second")
            let id = try await task(track, project: projectID, name: "Duplicate")
            _ = try await task(track, project: other, name: "Duplicate")
            _ = try await track.workspace.enqueueTimer(.start(taskID: id)).value
            let controller = MenuBarController(host: host, install: false)
            let before = track.workspace.snapshot
            for seconds: Int64 in [0, 1, 59, 60, 3599, 3600, 86400] {
                clock.set(100 + seconds)
                controller.refresh(at: Date(timeIntervalSince1970: Double(100 + seconds)))
                #expect(controller.status.title == MenuBarStatus.elapsed(seconds))
                #expect(controller.status.accessibilityLabel.contains("First / Duplicate"))
            }
            #expect(track.workspace.snapshot == before)  // Display samples cannot checkpoint.
            host.sleeping = true
            controller.refresh(at: Date())
            #expect(controller.status.systemImage == "moon.zzz")
            host.sleeping = false
            clock.set(99)
            controller.refresh(at: Date(timeIntervalSince1970: 99))
            #expect(controller.status.title.isEmpty)
            controller.refresh(at: Date(timeIntervalSince1970: .infinity))
            #expect(controller.status.title.isEmpty)
            await #expect(throws: TimerError.clockRollback) {
                try await track.workspace.enqueueTimer(.checkpoint).value
            }
            #expect(MenuBarStatus.project(host: host, at: Date()).accessibilityLabel.contains("paused"))
            await track.workspace.close()
            #expect(MenuBarStatus.project(host: host, at: Date()).accessibilityLabel.contains("unavailable"))
            try await track.workspace.open()
            #expect(MenuBarStatus.project(host: host, at: Date()).accessibilityLabel == "Time needs review")
            controller.invalidate()
            host.invalidate()
        }
    }

    @Test func runningWithPendingKeepsElapsedTitleAndDoesNotWrite() async throws {
        try await withTrack { track, directory in
            let suite = "MenuPendingTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let host = NativeHost(directory: directory, workspace: track.workspace, defaults: defaults)
            defer { host.invalidate() }
            host.recoveryPresentationHandler = { _ in }
            let lifecycle = Lifecycle(host: host)
            let clock = NativeClock()
            track.workspace.configureTimer(clock: { clock.read() })
            let projectID = try await project(track, name: "First")
            let id = try await task(track, project: projectID, name: "Work")
            _ = try await track.workspace.enqueueTimer(.start(taskID: id)).value
            clock.set(107)
            let baseline = MenuBarStatus.project(host: host, at: Date(timeIntervalSince1970: 107))
            #expect(baseline.title == "00:00:07")
            let controller = MenuBarController(host: host, install: false)
            defer { controller.invalidate() }
            clock.set(200)
            lifecycle.willSleep()
            await host.drain()
            lifecycle.didWake(at: Date(timeIntervalSince1970: 210))
            await host.drain()
            let before = try #require(track.workspace.snapshot)
            let active = try #require(before.activeTimer)
            #expect(before.pendingSleepInterval?.wakeAt == 210)
            #expect(track.workspace.timerStatus == .running(entryID: active.entryID))
            clock.set(217)
            for _ in 0..<3 {
                controller.refresh(at: Date(timeIntervalSince1970: 217))
                #expect(controller.status.title == baseline.title)
                #expect(controller.status.accessibilityLabel.contains("Tracking First / Work"))
                #expect(controller.status.accessibilityLabel.contains("unresolved sleep time must be resolved"))
            }
            #expect(track.workspace.snapshot == before)
        }
    }

}
