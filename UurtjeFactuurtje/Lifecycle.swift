import AppKit
import LibraryStore

@MainActor final class Lifecycle: NSObject, NSApplicationDelegate {
    let host: NativeHost
    static let checkpointInterval: TimeInterval = 15
    static let budgetInterval: TimeInterval = 1
    private var checkpoint: Timer?
    private var budget: Timer?
    private var observers: [NSObjectProtocol] = []
    private var sleepGeneration: UInt64?
    private(set) var sleeping = false
    private var menu: MenuBarController?
    private var notifications: BudgetNotifications?
    var confirmQuit: () async -> Bool = {
        let alert = NSAlert()
        alert.messageText = "Quitting will stop time tracking"
        alert.informativeText = "Pending or interrupted time must be reviewed before quitting."
        alert.addButton(withTitle: "Stop & Quit"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    var reply: (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }
    // The production close is infallible today; this seam also tests a future throwing adapter.
    var close: (WorkspaceModel) async throws -> Void = { await $0.enqueueClose().value }

    override convenience init() { self.init(host: NativeHost()) }
    init(host: NativeHost) { self.host = host; super.init() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        menu = MenuBarController(host: host)
        notifications = BudgetNotifications(path: { [weak host] id in host?.track.path(id) ?? id.uuidString },
                                            reveal: { [weak host] id in host?.revealNotificationTask(id) })
        host.publication = { [weak self] in
            guard let self else { return }
            self.menu?.refresh(at: Date())
            self.notifications?.consume(snapshot: self.host.available ? self.host.workspace.snapshot : nil,
                                        batches: self.host.workspace.budgetWarnings)
        }
        schedule()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            // AppKit posts on the main queue: latch before any asynchronous hop.
            MainActor.assumeIsolated { self?.willSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake(at: Date()) }
        })
        host.reopen()
    }
    private func schedule() {
        checkpoint = Self.scheduler(every: Self.checkpointInterval) { [weak self] in self?.checkpointTick() }
        budget = Self.scheduler(every: Self.budgetInterval) { [weak self] in self?.budgetTick() }
    }
    static func scheduler(every interval: TimeInterval, action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { action() } }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
    func checkpointTick() {
        guard host.acceptingMutations, !sleeping, case .running = host.workspace.timerStatus else { return }
        host.submitTimer(.checkpoint)
    }
    func budgetTick() {
        guard host.acceptingMutations, !sleeping, case .running = host.workspace.timerStatus,
              let usage = try? host.workspace.budgetUsage(), let snapshot = host.workspace.snapshot else { return }
        // A crossing must be committed before it can become a notification.
        if snapshot.tasks.contains(where: { task in
            guard let limit = task.budgetSeconds, let seconds = usage[task.id] else { return false }
            let band: Int64 = seconds >= Decimal(limit) ? 100 : seconds * 100 >= Decimal(limit) * 80 ? 80 : 0
            return band > task.lastWarnedThreshold.rawValue
        }) { host.submitTimer(.checkpoint) }
    }
    func applicationDidResignActive(_ notification: Notification) { checkpointTick() }
    func willSleep() {
        sleeping = true
        host.sleeping = true
        let generation = host.workspace.timerLifecycleGate.latchSleep()
        sleepGeneration = generation
        host.retain(host.workspace.enqueueSleepObservation(generation: generation))
        menu?.refresh(at: Date())
    }
    static func wholeSecond(_ date: Date) -> Int64? {
        let value = floor(date.timeIntervalSince1970)
        guard value.isFinite, value >= Double(Int64.min), value < Double(Int64.max) else { return nil }
        return Int64(value)
    }
    func didWake(at date: Date) {
        sleeping = false
        host.sleeping = false
        if let generation = sleepGeneration, let instant = Self.wholeSecond(date) {
            sleepGeneration = nil
            host.retain(host.workspace.enqueueWakeObservation(generation: generation, observedAt: instant))
        }
        menu?.refresh(at: date)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestQuit(); return .terminateLater
    }
    func requestQuit() {
        guard let token = host.beginQuit() else { return }
        Task { @MainActor in
            var permitted = false
            defer { host.finishQuit(token, cancelled: !permitted); reply(permitted) }
            await host.drain()
            guard !host.track.acceptedWork else { host.track.failure = "Finish the accepted editor operation before quitting."; return }
            if host.track.sheet != nil || host.workspace.snapshot?.activeTimer != nil {
                guard await confirmQuit() else { return }
            }
            // Confirmation may run a nested run loop; drain sleep/wake observations again.
            await host.drain()
            guard host.available, let snapshot = host.workspace.snapshot,
                  snapshot.pendingSleepIntervals.isEmpty, !sleeping else {
                host.track.failure = "Review unresolved time or reopen the library before quitting."
                host.openTrack(); return
            }
            if snapshot.activeTimer != nil {
                guard let stop = host.track.ownedStop else {
                    host.track.failure = "Review the interrupted timer before quitting."; host.openReview(); return
                }
                let result = host.workspace.enqueueTimer(stop)
                do { _ = try await result.value }
                catch { host.track.failure = "Stop was not confirmed: \(error)"; return }
            }
            await host.drain()
            guard host.available, !sleeping, host.workspace.snapshot?.activeTimer == nil,
                  host.workspace.snapshot?.pendingSleepIntervals.isEmpty == true else {
                host.track.failure = "Time changed during quit; review before trying again."; return
            }
            do {
                try await close(host.workspace)
                guard host.workspace.availability == .closed else { throw LibraryAccessError.unavailable }
                permitted = true
            } catch {
                host.track.failure = "Close failed. Reopen and inspect; no Stop or write was replayed. \(error)"
                host.openTrack()
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        checkpoint?.invalidate(); budget?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll(); menu?.invalidate(); host.invalidate()
    }
}
