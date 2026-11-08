import AppKit
import Observation
import LibraryStore

@MainActor @Observable final class NativeHost {
    let workspace: WorkspaceModel
    let track: TrackPresentation
    let directory: URL
    var acceptingMutations: Bool { quitAttempt == nil && available }
    private(set) var quitAttempt: UUID?
    var sleeping = false
    private(set) var recoveryDetails = ""
    // Commands install these during graph evaluation; replacing callbacks must not invalidate that graph.
    @ObservationIgnored private var openWindow: (() -> Void)?
    @ObservationIgnored private var settingsAction: (() -> Void)?
    private enum Route { case track, reports, review, settings, task(UUID), newTask, project, time }
    private var pending: [Route] = []
    private var accepted: [UUID: Task<Void, Never>] = [:]
    private var observing = true
    var publication: (() -> Void)?

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("UurtjeFactuurtje", isDirectory: true),
         workspace: WorkspaceModel? = nil, defaults: UserDefaults = .standard) {
        self.directory = directory
        let model = workspace ?? WorkspaceModel(directory: directory)
        self.workspace = model
        track = TrackPresentation(workspace: model, defaults: defaults)
        track.acceptingMutations = { [weak self] in self?.acceptingMutations == true }
        observe()
    }

    var available: Bool { workspace.availability == .ready || workspace.availability == .reviewRequired }
    func installSceneActions(workspace: @escaping () -> Void, settings: @escaping () -> Void) {
        openWindow = workspace; settingsAction = settings; flushRoutes()
    }
    func openTrack() { route(.track) }
    func openReports() { route(.reports) }
    func openReview() { route(.review) }
    func openSettings() { route(.settings) }
    func revealNotificationTask(_ id: UUID) { route(.task(id)) }
    func newTask() { if acceptingMutations { route(.newTask) } }
    func newProject() { if acceptingMutations { route(.project) } }
    func addTime() { if acceptingMutations { route(.time) } }
    private func route(_ route: Route) { pending.append(route); flushRoutes() }
    private func flushRoutes() {
        guard let openWindow else { return }
        while let route = pending.first {
            if case .settings = route {
                guard let settingsAction else { return }
                pending.removeFirst(); settingsAction(); continue
            }
            openWindow()
            guard available else { return }
            pending.removeFirst()
            switch route {
            case .track: track.destination = .track
            case .reports: track.destination = .reports
            case .review: track.destination = .track; track.reviewTime()
            case .task(let id): track.revealTask(id)
            case .newTask:
                track.destination = .track
                let project = track.projects.first { $0.id == track.selectedProjectID && !$0.isArchived }
                    ?? track.projects.first { !$0.isArchived }
                if let project { track.newTask(projectID: project.id) } else { track.editProject() }
            case .project: track.destination = .track; track.editProject()
            case .time: track.destination = .track; track.addTime(taskID: track.selectedTaskID)
            case .settings: break
            }
        }
    }
    func reopen() {
        guard quitAttempt == nil, !workspace.isBusy,
              workspace.availability == .blocked || workspace.availability == .closed else { return }
        let result = workspace.enqueueOpen()
        retain(Task { @MainActor in
            do { try await result.value; self.flushRoutes() }
            catch { self.track.failure = String(describing: error) }
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
        }
    }
    func beginQuit() -> UUID? {
        guard quitAttempt == nil else { return nil }
        let token = UUID(); quitAttempt = token
        recoveryDetails = "Library: \(directory.path)\nLast confirmed snapshot: \(String(describing: workspace.snapshot))"
        return token
    }
    func finishQuit(_ token: UUID, cancelled: Bool) {
        guard quitAttempt == token else { return }
        if cancelled { quitAttempt = nil }
    }
    func drain() async {
        while !accepted.isEmpty {
            let tasks = Array(accepted.values)
            for task in tasks { await task.value }
        }
        await waitForWorkspace()
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
    private func observe() {
        guard observing else { return }
        withObservationTracking {
            _ = workspace.snapshot; _ = workspace.availability; _ = workspace.issue
            _ = workspace.budgetWarnings; _ = workspace.isBusy
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observing else { return }
                self.observe(); self.flushRoutes(); self.publication?()
            }
        }
    }
    func invalidate() { observing = false; publication = nil }
}
