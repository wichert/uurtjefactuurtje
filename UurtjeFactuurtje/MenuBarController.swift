import AppKit
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
                ? state("Time needs review", "exclamationmark.clock") : state("Tracking stopped", "MenuIcon")
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
            return MenuBarStatus(title: elapsed(seconds), systemImage: "MenuIcon",
                                 accessibilityLabel: "Tracking \(host.track.path(entry.taskID)), \(elapsed(seconds)) elapsed" + pendingDescription)
        }
    }
    static func elapsed(_ seconds: Int64) -> String {
        String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

@MainActor final class MenuBarController: NSObject, NSMenuDelegate, NSSearchFieldDelegate {
    static let displayInterval: TimeInterval = 1
    let host: NativeHost
    private var item: NSStatusItem?
    let menu = NSMenu()
    let searchField = NSSearchField(frame: NSRect(x: 12, y: 4, width: 256, height: 22))
    private let searchMenuItem = NSMenuItem()
    private var displayTimer: Timer?
    private var isMenuOpen = false
    private(set) var status: MenuBarStatus
    var query: String {
        get { searchField.stringValue }
        set {
            searchField.stringValue = newValue
            rebuildMenu()
        }
    }
    private var projection = WorkspaceMenuProjection()

    struct WorkspaceMenuProjection: Equatable {
        var stopTitle: String?
        var startIDs: [UUID] = []
        var enabled = true
    }

    init(host: NativeHost, install: Bool = true) {
        self.host = host; status = MenuBarStatus.project(host: host, at: Date())
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        configureSearchItem()
        rebuildMenu()
        if install {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            self.item = item
            item.menu = menu
            displayTimer = Lifecycle.scheduler(every: Self.displayInterval) { [weak self] in self?.refresh(at: Date()) }
        }
        refresh(at: Date())
    }

    private func configureSearchItem() {
        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.focusRingType = .default
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Search tasks")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 30))
        searchField.frame = NSRect(x: 12, y: 4, width: 256, height: 22)
        searchField.autoresizingMask = [.width]
        container.addSubview(searchField)
        searchMenuItem.view = container
    }
    static func image(for status: MenuBarStatus) -> NSImage? {
        guard status.systemImage == "MenuIcon" else {
            return NSImage(systemSymbolName: status.systemImage, accessibilityDescription: nil)
        }
        guard let symbol = Bundle.main.image(forResource: status.systemImage) else { return nil }
        // NSStatusBarButton does not draw custom NSSymbolImageRep images directly.
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }
    func refresh(at date: Date) {
        status = MenuBarStatus.project(host: host, at: date)
        if isMenuOpen { rebuildMenuIfChanged() }
        guard let button = item?.button else { return }
        button.title = status.title
        button.image = Self.image(for: status)
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel(status.accessibilityLabel)
        // Updating the value is not an announcement: VoiceOver reads it on focus.
        button.toolTip = status.accessibilityLabel
    }
    func rebuildMenuIfChanged() {
        let next = WorkspaceMenuProjection(
            stopTitle: WorkspaceMenu.stopTitle(host.track),
            startIDs: WorkspaceMenu.recentTasks(host.track) + WorkspaceMenu.matchingTasks(host.track, query: searchField.stringValue),
            enabled: host.acceptingMutations
        )
        guard next != projection else { return }
        rebuildMenu()
    }

    func rebuildMenu() {
        let track = host.track
        let enabled = host.acceptingMutations
        let startIDs = WorkspaceMenu.recentTasks(track) + WorkspaceMenu.matchingTasks(track, query: searchField.stringValue)
        projection = WorkspaceMenuProjection(stopTitle: WorkspaceMenu.stopTitle(track), startIDs: startIDs, enabled: enabled)
        var leading: [NSMenuItem] = []
        if let stopTitle = WorkspaceMenu.stopTitle(track) {
            let stopItem = NSMenuItem(title: stopTitle, action: #selector(stopTimer(_:)), keyEquivalent: "")
            stopItem.target = self
            stopItem.isEnabled = enabled
            leading.append(stopItem)
        }
        for id in WorkspaceMenu.recentTasks(track) {
            leading.append(makeStartItem(taskID: id, enabled: enabled))
        }

        var trailing: [NSMenuItem] = []
        for id in WorkspaceMenu.matchingTasks(track, query: searchField.stringValue) {
            trailing.append(makeStartItem(taskID: id, enabled: enabled))
        }
        trailing.append(.separator())
        let openItem = NSMenuItem(title: "Open main window", action: #selector(openMainWindow(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.isEnabled = true
        trailing.append(openItem)
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "")
        quitItem.target = self
        quitItem.isEnabled = true
        trailing.append(quitItem)

        if let searchIndex = menu.items.firstIndex(of: searchMenuItem) {
            for index in stride(from: searchIndex - 1, through: 0, by: -1) {
                menu.removeItem(at: index)
            }
            for (offset, item) in leading.enumerated() {
                menu.insertItem(item, at: offset)
            }
            let newSearchIndex = leading.count
            while menu.items.count > newSearchIndex + 1 {
                menu.removeItem(at: menu.items.count - 1)
            }
            for item in trailing {
                menu.addItem(item)
            }
        } else {
            menu.removeAllItems()
            for item in leading {
                menu.addItem(item)
            }
            menu.addItem(searchMenuItem)
            for item in trailing {
                menu.addItem(item)
            }
        }
    }

    private func makeStartItem(taskID: UUID, enabled: Bool) -> NSMenuItem {
        let title = WorkspaceMenu.startTitle(host.track, taskID: taskID)
        let item = NSMenuItem(title: title, action: #selector(startTask(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = taskID
        item.isEnabled = enabled
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        searchField.stringValue = ""
        rebuildMenu()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isMenuOpen else { return }
            self.searchField.window?.makeFirstResponder(self.searchField)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    func controlTextDidChange(_ obj: Notification) {
        rebuildMenu()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if let firstMatch = WorkspaceMenu.matchingTasks(host.track, query: searchField.stringValue).first,
               host.acceptingMutations {
                host.submitTimer(.start(taskID: firstMatch))
                menu.cancelTracking()
            }
            return true
        }
        return false
    }

    @objc func stopTimer(_ sender: NSMenuItem) {
        guard let stop = host.track.ownedStop else { return }
        host.submitTimer(stop)
    }

    @objc func startTask(_ sender: NSMenuItem) {
        guard let taskID = sender.representedObject as? UUID else { return }
        host.submitTimer(.start(taskID: taskID))
    }

    @objc func openMainWindow(_ sender: NSMenuItem) {
        host.openTrack()
    }

    @objc func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    func invalidate() {
        displayTimer?.invalidate(); displayTimer = nil
        menu.cancelTracking()
        if let item { NSStatusBar.system.removeStatusItem(item) }; item = nil
    }
}
