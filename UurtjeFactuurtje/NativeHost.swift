import AppKit
import Observation
import LibraryStore

@MainActor @Observable final class NativeHost {
    let workspace: WorkspaceModel
    let track: TrackPresentation
    let reports: ReportsPresentation
    let directory: URL
    var acceptingMutations: Bool { quitAttempt == nil && available }
    private(set) var quitAttempt: UUID?
    var sleeping = false
    private(set) var recoveryDetails = ""
    // Commands install these during graph evaluation; replacing callbacks must not invalidate that graph.
    @ObservationIgnored private var openWindow: (() -> Void)?
    @ObservationIgnored private var settingsAction: (() -> Void)?
    private enum Route {
        case track, reports, projectReport(UUID, UUID?), review, settings, task(UUID), newTask, project, time
    }
    private var pending: [Route] = []
    private(set) var pendingAutoReview = false
    @ObservationIgnored var information: ((UUID, String) -> Void)?
    @ObservationIgnored private var flushingRoutes = false
    private var accepted: [UUID: Task<Void, Never>] = [:]
    private var observing = true
    var publication: (() -> Void)?

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("UurtjeFactuurtje", isDirectory: true),
         workspace: WorkspaceModel? = nil, defaults: UserDefaults = .standard) {
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
            availability: workspace.availability,
        )
    }

    var recoveryDiagnostics: String {
        var lines = ["Library: \(directory.path)",
                     "Workspace state: \(String(describing: workspace.availability))"]
        if let snapshot = workspace.snapshot {
            lines.append("Last confirmed revision: \(snapshot.revision)")
            if let active = snapshot.activeTimer {
                lines.append("Last confirmed checkpoint (epoch seconds): \(active.checkpointAt)")
                lines.append("Timer entry: \(active.entryID.uuidString)")
            }
        } else {
            lines.append("No confirmed snapshot is available.")
        }
        if let issue = workspace.issue { lines.append("Workspace issue: \(String(describing: issue))") }
        if hasUncertainPublication {
            lines.append(
                "Unresolved publication uncertainty: explicit confirmed reopen and inspection required; no replay."
            )
        }
        if let failure = reopenFailure {
            lines.append("Last explicit reopen error (historical): \(failure)")
        }
        if let failure = track.failure {
            lines.append("Last editor/action error (historical; inspect the affected draft): \(failure)")
        }
        return lines.joined(separator: "\n")
    }

    func installSceneActions(workspace: @escaping () -> Void, settings: @escaping () -> Void) {
        openWindow = workspace; settingsAction = settings; flushRoutes()
    }
    func openTrack() { route(.track) }
    func openReports() { route(.reports) }
    func openReview() {
        if case .timeReview = track.sheet {
            pendingAutoReview = false
            track.destination = .track
            return
        }
        route(.review)
    }

    func openProjectReport(projectID: UUID, scopeTaskID: UUID? = nil) {
        route(.projectReport(projectID, scopeTaskID))
    }

    private var needsTimeReview: Bool {
        workspace.snapshot?.pendingSleepIntervals.isEmpty == false
            || workspace.timerStatus == .reviewRequired
            || workspace.availability == .reviewRequired
    }

    private var canPresentAutoReview: Bool {
        needsTimeReview && available && workspace.snapshot != nil && !hasUncertainPublication
            && track.sheet == nil && track.suspendedTaskDraft == nil && !track.acceptedWork
            && !workspace.isBusy && quitAttempt == nil && !sleeping
    }

    func requestAutoReviewIfNeeded() {
        if needsTimeReview { pendingAutoReview = true }
        flushRoutes()
    }

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
        guard !flushingRoutes, let openWindow else { return }
        // Scene callbacks can synchronously reinstall actions and re-enter this method.
        flushingRoutes = true
        defer { flushingRoutes = false }
        flushPendingRoutes(openWindow: openWindow)
        flushAutomaticReview(openWindow: openWindow)
    }

    private func flushPendingRoutes(openWindow: () -> Void) {
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

    private func flushAutomaticReview(openWindow: () -> Void) {
        guard pendingAutoReview else { return }
        if available, !workspace.isBusy, !needsTimeReview {
            pendingAutoReview = false
            return
        }
        if case .timeReview = track.sheet {
            pendingAutoReview = false
            return
        }
        guard canPresentAutoReview else { return }
        pendingAutoReview = false
        presentAutomaticReview(openWindow: openWindow)
    }

    private func presentAutomaticReview(openWindow: () -> Void) {
        track.destination = .track
        track.reviewTime()
        openWindow()
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
                self.flushRoutes()
            } catch {
                self.reopenFailure = String(describing: error)
            }
        })
    }
    func submitTimer(_ command: TimerCommand) {
        guard acceptingMutations, available else { return }
        let result = workspace.enqueueTimer(command)
        retain(Task { @MainActor in
            do {
                _ = try await result.value
            } catch {
                self.track.failure = String(describing: error)
            }
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
        }
    }
    func beginQuit() -> UUID? {
        guard quitAttempt == nil else { return nil }
        let token = UUID(); quitAttempt = token
        recoveryDetails = "Library: \(directory.path)"
            + "\nLast confirmed snapshot: \(String(describing: workspace.snapshot))"
        return token
    }
    func finishQuit(_ token: UUID, cancelled: Bool) {
        guard quitAttempt == token else { return }
        if cancelled {
            quitAttempt = nil
            flushRoutes()
        }
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
            withObservationTracking { _ = workspace.isBusy } onChange: {
                Task { @MainActor in continuation.resume() }
            }
        }
        await waitForWorkspace()
    }
}

@MainActor private extension NativeHost {
    func performNewTask() {
        let project = track.projects.first {
            $0.id == track.selectedProjectID && !$0.isArchived
        } ?? track.projects.first { !$0.isArchived }
        if let project {
            track.newTask(projectID: project.id)
        } else {
            track.editProject()
        }
    }

    private func performRoute(_ route: Route) {
        switch route {
        case .track: track.destination = .track
        case .reports: track.destination = .reports
        case let .projectReport(projectID, scopeTaskID):
            reports.openProject(projectID, scopeTaskID: scopeTaskID)
            track.destination = .reports
        case .review:
            track.destination = .track
            track.reviewTime()
            if case .timeReview = track.sheet { pendingAutoReview = false }
        case let .task(id): track.revealTask(id)
        case .newTask:
            track.destination = .track
            performNewTask()
        case .project:
            track.destination = .track
            track.editProject()
        case .time:
            track.destination = .track
            track.addTime(taskID: track.selectedTaskID)
        case .settings: break
        }
    }

}

@MainActor extension NativeHost {
    func observe() {
        guard observing else { return }
        withObservationTracking {
            _ = workspace.snapshot; _ = workspace.availability; _ = workspace.issue
            _ = workspace.budgetWarnings; _ = workspace.isBusy; _ = workspace.timerStatus
            _ = track.sheet; _ = track.suspendedTaskDraft; _ = track.acceptedWork
            _ = track.feedback; _ = quitAttempt; _ = sleeping
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
    }
}
