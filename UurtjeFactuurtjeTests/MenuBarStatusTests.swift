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

@Suite @MainActor struct MenuBarStatusTests {
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
}
