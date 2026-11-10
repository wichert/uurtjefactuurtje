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
    private var closingResources = false
    private var droppedCloseObservation = false
    private var reviewAfterClose = false
    lazy var confirmQuit: () async -> Bool = { @MainActor [weak self] in
        guard let self else { return false }
        let host = self.host
        let snapshot = host.workspace.snapshot
        let uncertain = host.hasUncertainPublication
        let unavailable = !host.available || snapshot == nil
        let running: Bool
        if case .running = host.workspace.timerStatus {
            running = !self.sleeping && !host.sleeping && host.track.ownedStop != nil
        } else { running = false }
        let draft: Bool
        if !host.track.acceptedWork {
            switch host.track.sheet {
            case .project, .task, .correction: draft = true
            default: draft = host.track.suspendedTaskDraft != nil
            }
        } else { draft = false }
        var details: [String] = []
        if uncertain {
            details.append("The last change may or may not have been saved. Quit will close the library without another write. On next launch, inspect entries and the timer before deciding on another action; do not repeat the uncertain change.")
        } else if unavailable {
            details.append("The library is unavailable. Quit will close its resources without another write. No additional save or Stop is confirmed; inspect the library when it can be opened again.")
        } else if running {
            details.append("Your running timer will be stopped once before closing the library.")
        } else if snapshot?.activeTimer != nil || self.sleeping || host.sleeping {
            details.append("Interrupted or sleeping tracking will be left unchanged for review on next launch. Quit will not invent an end or wake time.")
        }
        if !uncertain && !unavailable && snapshot?.pendingSleepIntervals.isEmpty == false {
            details.append("Saved pending sleep time will remain unbilled. Defer its review until next launch; Quit will not include or discard it.")
        }
        if draft {
            details.append("The open unsent editor draft, including any suspended task draft, will be discarded only if Quit succeeds. Cancel keeps the draft and window open. Accepted operations are not discarded.")
        }
        let alert = NSAlert()
        alert.messageText = draft ? "Discard unsent draft and quit?" : "Quit UurtjeFactuurtje?"
        alert.informativeText = details.joined(separator: "\n\n")
        alert.addButton(withTitle: draft ? "Discard Draft & Quit" :
            (running && !uncertain && !unavailable ? "Stop & Quit" : "Quit"))
        alert.addButton(withTitle: "Cancel")
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
        host.information = { [weak self] id, message in
            self?.notifications?.notify(id: id, title: "UurtjeFactuurtje", body: message)
        }
        host.publication = { [weak self] in
            guard let self else { return }
            self.menu?.refresh(at: Date())
            self.notifications?.consume(snapshot: self.host.available ? self.host.workspace.snapshot : nil,
                                        batches: self.host.workspace.budgetWarnings,
                                        acknowledge: { self.host.workspace.dismissBudgetWarning($0) })
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
            guard let limit = task.budgetMinutes, let seconds = usage[task.id] else { return false }
            return BudgetRules.band(used: seconds, budget: limit).rawValue > task.lastWarnedThreshold.rawValue
        }) { host.submitTimer(.checkpoint) }
    }
    func applicationDidResignActive(_ notification: Notification) { checkpointTick() }
    func willSleep() {
        sleeping = true
        host.sleeping = true
        let generation = host.workspace.timerLifecycleGate.latchSleep()
        sleepGeneration = generation
        guard !closingResources else { droppedCloseObservation = true; return }
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
        guard !closingResources else {
            droppedCloseObservation = true
            sleepGeneration = nil
            return
        }
        if reviewAfterClose {
            reviewAfterClose = false
            sleepGeneration = nil
            host.workspace.requireTimerReviewAfterClose(sleeping: false)
            host.requestAutoReviewIfNeeded()
            menu?.refresh(at: date)
            return
        }
        if let generation = sleepGeneration, let instant = Self.wholeSecond(date) {
            sleepGeneration = nil
            let observation = host.workspace.enqueueWakeObservation(generation: generation, observedAt: instant)
            host.retain(Task { @MainActor [host] in
                await observation.value
                host.requestAutoReviewIfNeeded()
            })
        } else {
            host.requestAutoReviewIfNeeded()
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
            defer {
                if !permitted { closingResources = false }
                host.finishQuit(token, cancelled: !permitted)
                reply(permitted)
            }
            await host.drain()
            guard !host.track.acceptedWork else {
                host.track.failure = "Finish the accepted editor operation before quitting. It has not been discarded."
                return
            }
            let reviewed = host.workspace.snapshot
            let availability = host.workspace.availability
            let uncertain = host.hasUncertainPublication
            let generation = host.workspace.timerLifecycleGate.currentGeneration
            let wasSleeping = sleeping || host.sleeping
            let needsConfirmation = host.track.sheet != nil || host.track.suspendedTaskDraft != nil
                || reviewed?.activeTimer != nil || reviewed?.pendingSleepIntervals.isEmpty == false
                || !host.available || reviewed == nil || uncertain || wasSleeping
            if needsConfirmation {
                guard await confirmQuit() else { return }
            }
            await host.drain()
            // Consent cannot authorize new rows, a new sleep generation or a newly unknown save.
            guard !host.track.acceptedWork, host.workspace.snapshot == reviewed,
                  host.workspace.availability == availability,
                  host.hasUncertainPublication == uncertain,
                  host.workspace.timerLifecycleGate.currentGeneration == generation,
                  (sleeping || host.sleeping) == wasSleeping else {
                host.track.failure = "Time or library state changed during Quit. Inspect it, then choose Quit again. No Stop was repeated."
                return
            }
            if !uncertain, host.available, !wasSleeping,
               case .running = host.workspace.timerStatus {
                guard let stop = host.track.ownedStop else {
                    host.track.failure = "The running timer could not be safely identified. Inspect it before trying Quit again."
                    return
                }
                let result = host.workspace.enqueueTimer(stop)
                do { _ = try await result.value }
                catch {
                    host.track.failure = "Stop was not confirmed. Quit was cancelled; no Stop was repeated. Inspect the timer and library feedback. Choose Quit again only if you want to close in the state then shown. Details: \(error)"
                    return
                }
                await host.drain()
                guard !host.track.acceptedWork, host.available, !host.hasUncertainPublication,
                      !sleeping, !host.sleeping,
                      host.workspace.timerLifecycleGate.currentGeneration == generation,
                      host.workspace.snapshot?.activeTimer == nil,
                      host.workspace.snapshot?.pendingSleepIntervals == reviewed?.pendingSleepIntervals else {
                    host.track.failure = "Time or library state changed while stopping. Inspect it before choosing Quit again; no Stop was repeated."
                    return
                }
            }
            // No actor suspension between this seal and submitting resource close.
            droppedCloseObservation = false
            closingResources = true
            do {
                try await close(host.workspace)
                guard host.workspace.availability == .closed else { throw LibraryAccessError.unavailable }
                permitted = true
            } catch {
                // Reconcile before finishQuit releases admission, without replaying observations.
                if droppedCloseObservation {
                    reviewAfterClose = sleeping || host.sleeping
                    host.workspace.requireTimerReviewAfterClose(sleeping: reviewAfterClose)
                    host.requestAutoReviewIfNeeded()
                }
                host.track.failure = "Close failed. Reopen and inspect; interrupted tracking requires review. No Stop or write was replayed. \(error)"
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
