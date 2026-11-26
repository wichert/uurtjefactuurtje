import AppKit
import LibraryStore
import Observation
import SwiftUI

@MainActor private final class InterruptedTimeReviewPanel: NSViewController {
    private let controller: TimeReviewController
    private let snapshot: LibrarySnapshot
    private let task: String
    private let stack = NSStackView()
    private let picker = NSDatePicker()
    private let error = NSTextField(wrappingLabelWithString: "")
    private let disclosure = NSTextField(wrappingLabelWithString: "")
    private let reviewSave = NSButton(title: "Review Save & Stop", target: nil, action: nil)
    private let reviewDiscard = NSButton(title: "Review explicit discard", target: nil, action: nil)
    private let back = NSButton(title: "Back", target: nil, action: nil)
    private let confirm = NSButton(title: "Confirm reviewed action", target: nil, action: nil)
    private var end: LocalCorrectionTime
    private var command: TimeReviewCommand?
    private var runningConflict = false
    private var stale = false

    init(controller: TimeReviewController, task: String, snapshot: LibrarySnapshot) {
        self.controller = controller
        self.task = task
        self.snapshot = snapshot
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        end = CorrectionForm.fields(
            Date(timeIntervalSince1970: TimeInterval(snapshot.activeTimer!.checkpointAt)),
            calendar: calendar, preservingPrecision: true)
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let entry = snapshot.entries.first { $0.id == snapshot.activeTimer?.entryID }!
        let active = snapshot.activeTimer!
        let texts = [
            "Resolve interrupted time before continuing",
            "Pending time is not billed. Resolving an interruption stays stopped.",
            "Time zone captured when opened: \(TimeZone.current.identifier)",
            "Task: \(task)",
            "Start: \(EntryDisclosure.bound(entry.startAt, zone: .current))",
            "Durable checkpoint: \(EntryDisclosure.bound(active.checkpointAt, zone: .current))",
            "Checkpointed duration: \(EntryDisclosure.durationText(active.checkpointAt - entry.startAt))",
            "Explicit discard removes this interrupted entry and all its checkpointed time; nothing is "
                + "saved and tracking stays stopped."
        ]
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        for (index, text) in texts.enumerated() {
            let label = NSTextField(wrappingLabelWithString: text)
            if index == 0 { label.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
            stack.addArrangedSubview(label)
        }
        stack.addArrangedSubview(NSTextField(labelWithString: "Explicit end"))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.dateValue = CorrectionForm.pickerDate(for: end)
        picker.calendar = CorrectionForm.pickerCalendar
        picker.target = self
        picker.action = #selector(changed)
        stack.addArrangedSubview(picker)
        disclosure.maximumNumberOfLines = 0
        disclosure.isHidden = true
        error.textColor = .systemRed
        error.isHidden = true
        stack.addArrangedSubview(disclosure)
        stack.addArrangedSubview(error)
        reviewSave.target = self; reviewSave.action = #selector(save)
        reviewDiscard.target = self; reviewDiscard.action = #selector(discard)
        back.target = self; back.action = #selector(reset)
        confirm.target = self; confirm.action = #selector(commit)
        confirm.keyEquivalent = "\r"
        let actions = NSStackView(views: [reviewSave, reviewDiscard, NSView(), back, confirm])
        actions.orientation = .horizontal
        actions.spacing = 12
        stack.addArrangedSubview(actions)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let scroll = NSScrollView()
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        view = scroll
        update()
    }
    @objc private func changed() {
        end = CorrectionForm.applyingPickerDate(picker.dateValue, to: end)
        stale = command != nil
        update()
    }
    @objc private func save() { plan(skip: false) }
    @objc private func discard() { plan(skip: true) }
    @objc private func reset() {
        command = nil
        stale = false
        update()
    }
    @objc private func commit() {
        guard let command, !stale, !controller.stale, !runningConflict else { return }
        controller.submit(command)
        update()
        Task { @MainActor in self.update() }
    }
    private func plan(skip: Bool) {
        guard !controller.submitting else { return }
        controller.error = nil
        controller.stale = false
        do {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let preview = skip ? try SleepPlanner.interruption(endAt: nil, in: snapshot)
                : try TimeReviewView.saveAndStop(end: end, calendar: calendar, in: snapshot)
            command = .resolveInterruption(preview)
            runningConflict = preview.correction?.runningConflict != nil
            stale = false
            disclosure.stringValue = TimeReviewView.interruptionSummary(preview, zone: .current)
        } catch { controller.error = String(describing: error) }
        update()
    }
    private func update() {
        disclosure.isHidden = command == nil
        back.isHidden = command == nil
        confirm.isHidden = command == nil
        confirm.isEnabled = !stale && !controller.stale && !runningConflict && !controller.submitting
        reviewSave.isHidden = command != nil
        reviewDiscard.isHidden = command != nil
        picker.isEnabled = command == nil && !controller.submitting
        error.stringValue = controller.error ?? ""
        error.isHidden = controller.error == nil
    }
}

@MainActor private final class IdleTimeReviewPanel: NSViewController {
    private let controller: TimeReviewController
    private let row: PendingSleepInterval
    private let task: String
    private let error = NSTextField(wrappingLabelWithString: "")
    private var buttons: [NSButton] = []

    init(controller: TimeReviewController, task: String, row: PendingSleepInterval) {
        self.controller = controller
        self.task = task
        self.row = row
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let zone = TimeZone.current
        let duration = Duration.seconds(row.wakeAt! - row.sleepAt)
            .formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .wide))
        let texts = [
            "Track the time your Mac was asleep or locked?",
            "Task: \(task)", "Time away: \(duration)",
            "From \(EntryDisclosure.bound(row.sleepAt, zone: zone))",
            "To \(EntryDisclosure.bound(row.wakeAt!, zone: zone))",
            "Don’t Track leaves this interval unbilled."
        ]
        let stack = NSStackView(views: texts.enumerated().map { index, text -> NSView in
            let label = NSTextField(wrappingLabelWithString: text)
            if index == 0 { label.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
            return label
        })
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        error.textColor = .systemRed
        error.isHidden = true
        stack.addArrangedSubview(error)
        let skip = NSButton(title: "Don’t Track", target: self, action: #selector(skip))
        let include = NSButton(title: "Track Time", target: self, action: #selector(include))
        include.keyEquivalent = "\r"
        buttons = [skip, include]
        let actions = NSStackView(views: [NSView(), skip, include])
        actions.orientation = .horizontal
        actions.spacing = 12
        stack.addArrangedSubview(actions)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        view = stack
    }

    @objc private func skip() { submit(skip: true) }
    @objc private func include() { submit(skip: false) }
    private func submit(skip: Bool) {
        guard let snapshot = controller.presentation.workspace.snapshot else { return }
        do {
            let command: TimeReviewCommand = skip
                ? .skip(try SleepPlanner.skip(row, in: snapshot))
                : .include(try SleepPlanner.include(row, endAt: nil, in: snapshot))
            controller.submit(command)
            Task { @MainActor in self.update() }
        } catch { controller.error = String(describing: error); update() }
    }
    private func update() {
        error.stringValue = controller.error ?? ""
        error.isHidden = controller.error == nil
        buttons.forEach { $0.isEnabled = !controller.submitting }
    }
}

@MainActor @Observable final class NativeHost {
    let workspace: WorkspaceModel
    let track: TrackPresentation
    let reports: ReportsPresentation
    let directory: URL
    var acceptingMutations: Bool { quitAttempt == nil && available && !needsTimeReview && !recoveryPresented }
    private(set) var quitAttempt: UUID?
    var sleeping = false
    private(set) var recoveryDetails = ""
    @ObservationIgnored private var openWindow: (() -> Void)?
    @ObservationIgnored private var settingsAction: (() -> Void)?
    private enum Route {
        case track, reports
        case projectReport(UUID, UUID?)
        case settings
        case task(UUID)
        case newTask, project, time
    }
    private var pending: [Route] = []
    @ObservationIgnored var information: ((UUID, String) -> Void)?
    @ObservationIgnored private var flushingRoutes = false
    private var accepted: [UUID: Task<Void, Never>] = [:]
    private var observing = true
    var publication: (() -> Void)?
    @ObservationIgnored private(set) var recoveryPanel: NSPanel?
    @ObservationIgnored private var recoverySession: NSApplication.ModalSession?
    @ObservationIgnored private var recoveryPump: Timer?
    @ObservationIgnored private(set) var recoveryController: TimeReviewController?
    @ObservationIgnored var recoveryPresentationHandler: ((TimeReviewController) -> Void)?
    var recoveryPresented: Bool { recoveryController != nil }

    init(
        directory: URL = URL.applicationSupportDirectory.appendingPathComponent("UurtjeFactuurtje", isDirectory: true),
        workspace: WorkspaceModel? = nil, defaults: UserDefaults = .standard
    ) {
        self.directory = directory
        let model = workspace ?? WorkspaceModel(directory: directory)
        self.workspace = model
        let presentation = TrackPresentation(workspace: model, defaults: defaults)
        track = presentation
        reports = ReportsPresentation(track: presentation)
        track.acceptingMutations = { [weak self] in self?.acceptingMutations == true }
        observe()
    }

    var available: Bool { workspace.availability == .ready || workspace.availability == .reviewRequired }
    private(set) var reopenFailure: String?
    var hasUncertainPublication: Bool { workspace.publicationUncertain }
    var canReopen: Bool {
        quitAttempt == nil && !workspace.isBusy && !track.acceptedWork
            && (workspace.availability == .blocked || workspace.availability == .closed)
    }
    var hasRecoveryFeedback: Bool {
        hasUncertainPublication || workspace.issue != nil || reopenFailure != nil
            || track.failure != nil || workspace.availability == .blocked
            || workspace.availability == .reviewRequired
    }
    var recoveryMessage: String {
        RecoveryMessage.text(
            issue: hasUncertainPublication ? .uncertainSave : workspace.issue,
            availability: workspace.availability
        )
    }
    var recoveryDiagnostics: String {
        var lines = ["Library: \(directory.path)", "Workspace state: \(String(describing: workspace.availability))"]
        if let snapshot = workspace.snapshot {
            lines.append("Last confirmed revision: \(snapshot.revision)")
            if let active = snapshot.activeTimer {
                lines.append("Last confirmed checkpoint (epoch seconds): \(active.checkpointAt)")
                lines.append("Timer entry: \(active.entryID.uuidString)")
            }
        } else { lines.append("No confirmed snapshot is available.") }
        if let issue = workspace.issue { lines.append("Workspace issue: \(String(describing: issue))") }
        if hasUncertainPublication {
            lines.append(
                "Unresolved publication uncertainty: explicit confirmed reopen and inspection required; "
                    + "no replay."
            )
        }
        if let failure = reopenFailure { lines.append("Last explicit reopen error (historical): \(failure)") }
        if let failure = track.failure {
            lines.append("Last editor/action error (historical; inspect the affected draft): \(failure)")
        }
        return lines.joined(separator: "\n")
    }

    func installSceneActions(workspace: @escaping () -> Void, settings: @escaping () -> Void) {
        openWindow = workspace
        settingsAction = settings
        flushRoutes()
    }
    func openTrack() { route(.track) }
    func openReports() { route(.reports) }
    func openProjectReport(projectID: UUID, scopeTaskID: UUID? = nil) { route(.projectReport(projectID, scopeTaskID)) }
    private var needsTimeReview: Bool {
        if sleeping, workspace.snapshot?.activeTimer == nil { return false }
        return workspace.snapshot?.pendingSleepInterval != nil
            || (workspace.availability == .reviewRequired && workspace.snapshot?.activeTimer != nil)
    }
    func requestAutoReviewIfNeeded() { flushRoutes() }
    private func publishInformation() {
        guard let message = track.feedback, let information else { return }
        track.feedback = nil
        information(UUID(), message)
    }
    func openSettings() { route(.settings) }
    func revealNotificationTask(_ id: UUID) { route(.task(id)) }
    func newTask() { if acceptingMutations { route(.newTask) } }
    func newProject() { if acceptingMutations { route(.project) } }
    func addTime() { if acceptingMutations { route(.time) } }
    private func route(_ route: Route) { pending.append(route); flushRoutes() }
    private func flushRoutes() {
        guard observing, !flushingRoutes, let openWindow else { return }
        flushingRoutes = true
        defer { flushingRoutes = false }
        presentRecoveryIfNeeded(openWindow: openWindow)
        guard !needsTimeReview, !recoveryPresented else { return }
        while let route = pending.first {
            if case .settings = route {
                guard let settingsAction else { return }
                pending.removeFirst()
                settingsAction()
                continue
            }
            openWindow()
            guard available else { return }
            pending.removeFirst()
            performRoute(route)
        }
    }
    private func presentRecoveryIfNeeded(openWindow: () -> Void) {
        guard !sleeping, needsTimeReview, available, let snapshot = workspace.snapshot, !hasUncertainPublication,
            !workspace.isBusy, accepted.isEmpty, quitAttempt == nil, !recoveryPresented
        else { return }
        NSApp.activate(ignoringOtherApps: true)
        let controller = TimeReviewController(
            presentation: track,
            retain: { [weak self] task in self?.retain(task) },
            dismiss: { [weak self] in self?.dismissRecovery() }
        )
        recoveryController = controller
        if let recoveryPresentationHandler {
            recoveryPresentationHandler(controller)
            return
        }
        openWindow()
        let height: CGFloat = snapshot.pendingSleepInterval?.wakeAt != nil
            && (snapshot.activeTimer == nil || workspace.availability == .ready) ? 340 : 680
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: height),
            styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Resolve interrupted time"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        if let row = snapshot.pendingSleepInterval, row.wakeAt != nil,
            snapshot.activeTimer == nil || workspace.availability == .ready {
            panel.contentViewController = IdleTimeReviewPanel(
                controller: controller, task: track.path(row.taskID), row: row)
        } else {
            let taskID = snapshot.entries.first { $0.id == snapshot.activeTimer?.entryID }!.taskID
            panel.contentViewController = InterruptedTimeReviewPanel(
                controller: controller, task: track.path(taskID), snapshot: snapshot)
        }
        panel.setContentSize(NSSize(width: 620, height: height))
        panel.center()
        recoveryPanel = panel
        recoverySession = NSApp.beginModalSession(for: panel)
        // Pump modal events without blocking async store commits on the main actor.
        recoveryPump = Lifecycle.scheduler(every: 1.0 / 30) { [weak self] in
            if let session = self?.recoverySession { _ = NSApp.runModalSession(session) }
        }
    }
    private func dismissRecovery() {
        endRecoverySession()
        track.reconcile()
        flushRoutes()
        publication?()
    }
    private func endRecoverySession() {
        recoveryPump?.invalidate()
        recoveryPump = nil
        if let session = recoverySession { NSApp.endModalSession(session) }
        recoverySession = nil
        recoveryPanel?.orderOut(nil)
        recoveryPanel = nil
        recoveryController = nil
    }
    func reopen() {
        guard canReopen else { return }
        let result = workspace.enqueueOpen()
        retain(Task { @MainActor in
            do {
                try await result.value
                if self.available, self.workspace.snapshot != nil, !self.workspace.publicationUncertain {
                    self.reopenFailure = nil
                }
            } catch { self.reopenFailure = String(describing: error) }
        })
    }
    func submitTimer(_ command: TimerCommand) {
        guard acceptingMutations, available else { return }
        let result = workspace.enqueueTimer(command)
        retain(Task { @MainActor in
            do { _ = try await result.value } catch { self.track.failure = String(describing: error) }
        })
    }
    func submitFirstWeekday(_ weekday: Int) -> Task<Void, Error>? {
        guard acceptingMutations else { return nil }
        return workspace.enqueueFirstWeekday(weekday)
    }
    func retain(_ task: Task<Void, Never>) {
        let id = UUID()
        accepted[id] = Task { @MainActor in
            await task.value
            self.accepted[id] = nil
            self.flushRoutes()
        }
    }
    func beginQuit() -> UUID? {
        guard quitAttempt == nil else { return nil }
        if recoveryPresented || (needsTimeReview && available && !hasUncertainPublication) {
            requestAutoReviewIfNeeded()
            return nil
        }
        let token = UUID()
        quitAttempt = token
        recoveryDetails =
            "Library: \(directory.path)\nLast confirmed snapshot: \(String(describing: workspace.snapshot))"
        return token
    }
    func finishQuit(_ token: UUID, cancelled: Bool) {
        guard quitAttempt == token else { return }
        if cancelled { quitAttempt = nil; flushRoutes() }
    }
    func drain() async {
        while true {
            let tasks = Array(accepted.values)
            for task in tasks { await task.value }
            await waitForWorkspace()
            if accepted.isEmpty && !workspace.isBusy { return }
        }
    }
    private func waitForWorkspace() async {
        guard workspace.isBusy else { return }
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = workspace.isBusy } onChange: { Task { @MainActor in continuation.resume() } }
        }
        await waitForWorkspace()
    }
}

@MainActor extension NativeHost {
    fileprivate func performNewTask() {
        let project =
            track.projects.first { $0.id == track.selectedProjectID && !$0.isArchived }
            ?? track.projects.first { !$0.isArchived }
        if let project { track.newTask(projectID: project.id) } else { track.editProject() }
    }
    private func performRoute(_ route: Route) {
        switch route {
        case .track: track.destination = .track
        case .reports: track.destination = .reports
        case .projectReport(let projectID, let scopeTaskID):
            reports.openProject(projectID, scopeTaskID: scopeTaskID)
            track.destination = .reports
        case .task(let id): track.revealTask(id)
        case .newTask: track.destination = .track; performNewTask()
        case .project: track.destination = .track; track.editProject()
        case .time: track.destination = .track; track.addTime(taskID: track.selectedTaskID)
        case .settings: break
        }
    }
}

@MainActor extension NativeHost {
    func observe() {
        guard observing else { return }
        withObservationTracking {
            _ = workspace.snapshot
            _ = workspace.availability
            _ = workspace.issue
            _ = workspace.budgetWarnings
            _ = workspace.isBusy
            _ = workspace.timerStatus
            _ = track.sheet
            _ = track.suspendedTaskDraft
            _ = track.acceptedWork
            _ = track.feedback
            _ = quitAttempt
            _ = sleeping
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observing else { return }
                self.observe()
                self.flushRoutes()
                self.publishInformation()
                self.publication?()
            }
        }
    }
    func invalidate() {
        observing = false
        publication = nil
        information = nil
        recoveryPresentationHandler = nil
        endRecoverySession()
    }
}
