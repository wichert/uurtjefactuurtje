import AppKit
import SwiftUI
import LibraryStore

struct MenuBarStatus: Equatable {
    let title: String
    let systemImage: String
    let accessibilityLabel: String

    @MainActor static func project(host: NativeHost, at date: Date) -> MenuBarStatus {
        let model = host.workspace
        let pendingCount = model.snapshot?.pendingSleepIntervals.count ?? 0
        let pendingDescription = pendingCount > 0
            ? ", \(pendingCount) pending sleep interval(s) need review — unbilled" : ""
        func state(_ label: String, _ image: String) -> MenuBarStatus {
            MenuBarStatus(title: "", systemImage: image, accessibilityLabel: label + pendingDescription)
        }
        guard model.availability == .ready || model.availability == .reviewRequired else {
            return state("Tracking unavailable: \(model.availability)", "exclamationmark.circle")
        }
        if host.sleeping { return state("Tracking suspended for sleep", "moon.zzz") }
        switch model.timerStatus {
        case .idle:
            return model.snapshot?.pendingSleepIntervals.isEmpty == false
                ? state("Time needs review", "exclamationmark.clock") : state("Tracking stopped", "timer")
        case .reviewRequired: return state("Time needs review", "exclamationmark.clock")
        case .paused: return state("Tracking paused — review time", "pause.circle")
        case .running:
            guard let snapshot = model.snapshot, let active = snapshot.activeTimer,
                  let entry = snapshot.entries.first(where: { $0.id == active.entryID }),
                  let instant = Lifecycle.wholeSecond(date), instant >= active.checkpointAt,
                  host.track.eligible(entry.taskID),
                  let seconds = try? model.timerElapsedSeconds(), seconds >= 0 else {
                return state("Tracking paused — clock or timer needs review", "exclamationmark.clock")
            }
            return MenuBarStatus(title: elapsed(seconds), systemImage: "timer",
                                 accessibilityLabel: "Tracking \(host.track.path(entry.taskID)), \(elapsed(seconds)) elapsed" + pendingDescription)
        }
    }
    static func elapsed(_ seconds: Int64) -> String {
        String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

@MainActor final class MenuBarController: NSObject {
    static let displayInterval: TimeInterval = 1
    let host: NativeHost
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var displayTimer: Timer?
    private(set) var status: MenuBarStatus
    init(host: NativeHost, install: Bool = true) {
        self.host = host; status = MenuBarStatus.project(host: host, at: Date())
        super.init()
        if install {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            self.item = item
            item.button?.target = self; item.button?.action = #selector(toggle)
            popover.behavior = .transient
            let size = NSSize(width: 420, height: 560)
            let content = NSHostingController(rootView: WorkspaceMenu(host: host))
            content.preferredContentSize = size
            content.view.setFrameSize(size)
            popover.contentViewController = content
            popover.contentSize = size
            displayTimer = Lifecycle.scheduler(every: Self.displayInterval) { [weak self] in self?.refresh(at: Date()) }
        }
        refresh(at: Date())
    }
    func refresh(at date: Date) {
        status = MenuBarStatus.project(host: host, at: date)
        guard let button = item?.button else { return }
        button.title = status.title
        button.image = NSImage(systemSymbolName: status.systemImage, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel(status.accessibilityLabel)
        // Updating the value is not an announcement: VoiceOver reads it on focus.
        button.toolTip = status.accessibilityLabel
    }
    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item?.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
    func invalidate() {
        displayTimer?.invalidate(); displayTimer = nil; popover.performClose(nil)
        if let item { NSStatusBar.system.removeStatusItem(item) }; item = nil
    }
}
