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
        Self.recoveryMessage(issue: hasUncertainPublication ? .uncertainSave : workspace.issue,
                             availability: workspace.availability)
    }

    static func recoveryMessage(issue: WorkspaceIssue?, availability: WorkspaceAvailability) -> String {
        // An uncertain publication remains uncertain even if its last rows are still displayed.
        if issue == .uncertainSave {
            return "The last change may or may not have been saved. Do not repeat it or assume it is safe to discard. Reopen the library when available, then inspect its entries and timer before deciding what to do next."
        }
        switch availability {
        case .opening:
            return "Opening the library. Please wait; no failed action is being repeated."
        case .closing:
            return "Closing the library after accepted work finishes. Please wait."
        default: break
        }
        switch issue {
        case .busy:
            return "Another app or process is using this library. Close that library in the other process, then explicitly reopen it here. Do not delete lock files."
        case .unsafeLibrary:
            return "The library could not be opened safely. Keep its files intact. Copy the library location and diagnostic details before seeking help or restoring a known-good backup."
        case .invalidStorage:
            return "The stored library is damaged or uses an unsupported format. Keep its files intact. Check that you are using a compatible app version; seek help or use a known-good backup before reopening."
        case .revisionConflict:
            return availability == .blocked
                ? "The library changed, and refreshing its view failed. Retained rows may be stale. Explicitly reopen and inspect its entries and timer when available, then refresh the affected editor before deciding on a new action. The failed action was not automatically repeated."
                : "The library changed since this action was prepared. Inspect the confirmed rows and refresh the affected editor before deciding on a new action. The failed action was not automatically repeated."
        case .recoveryRequired:
            return "Time needs review before this action can continue. Open time review and inspect the timer and any pending intervals. Pending sleep time is unbilled."
        case .command:
            return "This action could not be completed. Inspect the affected item and the editor's explanation before deciding on a new action."
        case .validation:
            return availability == .blocked
                ? "The library contains data that could not be accepted. Keep its files intact and copy the diagnostic details before seeking help."
                : "Some data could not be accepted. Review the affected fields and the editor's explanation before deciding on a new action."
        case .unavailable, .closed:
            return "The library is unavailable. When reopening is available, explicitly reopen and inspect its entries and timer before making another change."
        case .other:
            return "The action could not be completed. Copy the diagnostic details if you need help. Inspect the library before deciding on another action; no failed action is automatically repeated."
        case .uncertainSave: // Handled before availability above.
            return "The save outcome is unknown. Inspect the library before making another change."
        case nil:
            switch availability {
            case .closed: return "The library is closed. Explicitly reopen it to inspect your work."
            case .blocked: return "The library is blocked. Copy the diagnostic details, then explicitly reopen and inspect it when the underlying problem is resolved."
            case .reviewRequired: return "Time needs review. Inspect the timer and any pending intervals; pending sleep time is unbilled."
            case .ready: return "A previous operation reported an error. This is historical feedback, not a current library failure. Inspect the diagnostic details and affected item before deciding what to do next."
            case .opening, .closing: return "Please wait for the library operation to finish."
            }
        }
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
            lines.append("Unresolved publication uncertainty: explicit confirmed reopen and inspection required; no replay.")
        }
        if let failure = reopenFailure { lines.append("Last explicit reopen error (historical): \(failure)") }
        if let failure = track.failure { lines.append("Last editor/action error (historical; inspect the affected draft): \(failure)") }
        return lines.joined(separator: "\n")
    }

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
