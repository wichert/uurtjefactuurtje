import Foundation
import Observation
import LibraryStore
private struct OutlineCacheKey: Equatable {
    let revision: Int64, showArchived: Bool, search: String, localeIdentifier: String
}
@MainActor @Observable final class TrackPresentation {
    @ObservationIgnored private var outlineCache: (key: OutlineCacheKey, rows: [TrackOutlineRow])?
    func outlineRows() -> [TrackOutlineRow] {
        guard let snapshot = workspace.snapshot else { outlineCache = nil; return [] }
        let key = OutlineCacheKey(revision: snapshot.revision, showArchived: showArchived,
                                  search: search, localeIdentifier: Locale.current.identifier)
        if let outlineCache, outlineCache.key == key { return outlineCache.rows }
        let visibleProjects = snapshot.projects.filter { showArchived || !$0.isArchived }.sorted {
            let result = $0.name.localizedStandardCompare($1.name)
            return result == .orderedSame
                ? $0.id.uuidString < $1.id.uuidString : result == .orderedAscending
        }
        let projectIDs = Set(visibleProjects.map(\.id))
        let tasks = snapshot.tasks.filter { projectIDs.contains($0.projectID) }
        let roots = Dictionary(grouping: tasks.filter { $0.parentTaskID == nil }, by: \.projectID)
        let children = Dictionary(grouping: tasks.compactMap { task in
            task.parentTaskID.map { (parent: $0, task: task) }
        }, by: \.parent).mapValues { $0.map(\.task) }
        func ordered(_ tasks: [TaskRecord]) -> [TaskRecord] {
            tasks.sorted {
                let result = $0.name.localizedStandardCompare($1.name)
                return result == .orderedSame
                    ? $0.id.uuidString < $1.id.uuidString : result == .orderedAscending
            }
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = visibleProjects.compactMap { project in
            outline(project, roots: roots, children: children, ordered: ordered, query: query)
        }
        outlineCache = (key, result)
        return result
    }
    private struct OutlineNode {
        let task: TaskRecord, path: String, childIDs: [UUID], included: Bool
    }
    private func outline(_ project: Project, roots: [UUID: [TaskRecord]], children: [UUID: [TaskRecord]],
                         ordered: ([TaskRecord]) -> [TaskRecord], query: String) -> TrackOutlineRow? {
        let projectRoots = ordered(roots[project.id] ?? [])
        let projectMatches = query.isEmpty || project.name.localizedStandardContains(query)
        var stack = projectRoots.reversed().map { ($0, project.name, projectMatches) }
        var preorder: [OutlineNode] = []
        var visited = Set<UUID>()
        while let (task, prefix, ancestorMatches) = stack.popLast() {
            guard visited.insert(task.id).inserted else { continue }
            let path = prefix + " / " + task.name
            let descendants = ordered(children[task.id] ?? [])
            preorder.append(OutlineNode(task: task, path: path,
                                        childIDs: descendants.map(\.id), included: ancestorMatches))
            for child in descendants.reversed() { stack.append((child, path, ancestorMatches)) }
        }
        var built: [UUID: TrackOutlineRow] = [:]
        for item in preorder.reversed() {
            // Removing transferred children avoids retaining another complete tree in this dictionary.
            let nested = item.childIDs.compactMap { built.removeValue(forKey: $0) }
            let included = item.included || item.path.localizedStandardContains(query) || !nested.isEmpty
            guard included else { continue }
            built[item.task.id] = TrackOutlineRow(
                id: .task(item.task.id), projectID: project.id,
                title: item.task.name, path: item.path, isArchived: project.isArchived,
                isLeafTask: item.childIDs.isEmpty, children: nested)
        }
        let nested = projectRoots.compactMap { built.removeValue(forKey: $0.id) }
        guard query.isEmpty || projectMatches || !nested.isEmpty else { return nil }
        return TrackOutlineRow(id: .project(project.id), projectID: project.id,
            title: project.name, path: project.name, isArchived: project.isArchived,
            isLeafTask: false, children: nested)
    }
    func isVisible(_ id: TrackRowID) -> Bool {
        let searching = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var stack = outlineRows()
        while let row = stack.popLast() {
            if row.id == id { return true }
            let expanded: Bool
            switch row.id {
            case .project(let id): expanded = expandedProjectIDs.contains(id)
            case .task(let id): expanded = expandedTaskIDs.contains(id)
            }
            if searching || expanded { stack.append(contentsOf: row.children) }
        }
        return false
    }
    let workspace: WorkspaceModel
    private let defaults: UserDefaults
    // Filter the cache using revision and filter inputs as its invalidation key.
    var destination: WorkspaceDestination = .track
    private struct Selection { var projectID: UUID?, taskID: UUID? }
    private var selection: Selection { didSet { persist() } }
    var expandedProjectIDs: Set<UUID> { didSet { persist() } }
    var expandedTaskIDs: Set<UUID> { didSet { persist() } }
    var showArchived = false
    var search = ""
    private(set) var sheet: TrackSheet?
    private(set) var routeToken = UUID()
    private(set) var reveal: TaskReveal?
    private(set) var suspendedTaskDraft: TaskDraft?
    private(set) var acceptedWork = false
    var acceptingMutations: () -> Bool = { true }
    var feedback: String?
    var failure: String?
    init(workspace: WorkspaceModel, defaults: UserDefaults = .standard) {
        self.workspace = workspace
        self.defaults = defaults
        let savedProject = defaults.string(forKey: "track.project").flatMap(UUID.init(uuidString:))
        let savedTask = defaults.string(forKey: "track.task").flatMap(UUID.init(uuidString:))
        let owner = savedTask.flatMap { id in workspace.snapshot?.tasks.first { $0.id == id }?.projectID }
        selection = Selection(projectID: owner ?? savedProject, taskID: savedTask)
        expandedProjectIDs = Set((defaults.stringArray(forKey: "track.expandedProjects") ?? [])
            .compactMap(UUID.init(uuidString:)))
        expandedTaskIDs = Set((defaults.stringArray(forKey: "track.expanded") ?? [])
            .compactMap(UUID.init(uuidString:)))
    }
    var selectedRow: TrackRowID? {
        get {
            if let id = selection.taskID { return .task(id) }
            return selection.projectID.map { .project($0) }
        }
        set {
            switch newValue {
            case .project(let id):
                selection = Selection(projectID: id, taskID: nil)
            case .task(let id):
                guard let task = workspace.snapshot?.tasks.first(where: { $0.id == id }) else { return }
                selection = Selection(projectID: task.projectID, taskID: id)
            case nil:
                selection = Selection(projectID: nil, taskID: nil)
            }
        }
    }
    var selectedProjectID: UUID? {
        get { selection.projectID }
        set {
            let task = selection.taskID.flatMap { id in
                workspace.snapshot?.tasks.first { $0.id == id && $0.projectID == newValue }
            }
            selection = Selection(projectID: newValue, taskID: task?.id)
        }
    }
    var selectedTaskID: UUID? {
        get { selection.taskID }
        set {
            let task = newValue.flatMap { id in workspace.snapshot?.tasks.first { $0.id == id } }
            selection = Selection(projectID: task?.projectID ?? selection.projectID, taskID: newValue)
        }
    }
    private func persist() {
        defaults.set(selection.projectID?.uuidString, forKey: "track.project")
        defaults.set(selection.taskID?.uuidString, forKey: "track.task")
        defaults.set(expandedProjectIDs.map(\.uuidString).sorted(), forKey: "track.expandedProjects")
        defaults.set(expandedTaskIDs.map(\.uuidString).sorted(), forKey: "track.expanded")
    }
    @discardableResult func begin(_ token: UUID) -> Bool {
        guard acceptingMutations(), token == routeToken, !acceptedWork else { return false }
        acceptedWork = true; failure = nil; return true
    }
    func complete(_ token: UUID, error: Error? = nil) {
        guard token == routeToken else { return }
        acceptedWork = false
        if let error { failure = String(describing: error); return }
        let completed = sheet
        let restoringChild = suspendedTaskDraft != nil
        cancelSheet()
        reconcile()
        guard !restoringChild else { return }
        switch completed {
        case .project(let draft) where draft.isNew:
            guard let snapshot = workspace.snapshot,
                  let project = snapshot.projects.first(where: { $0.id == draft.id }) else { return }
            destination = .track
            search = ""
            selectedRow = .project(project.id)
            expandedProjectIDs.insert(project.id)
            reveal = nil
            if project.isArchived { showArchived = true }
            if snapshot.projects.count == 1 { newTask(projectID: project.id) }
        case .task(let draft) where draft.isNew:
            guard workspace.snapshot?.tasks.contains(where: { $0.id == draft.id }) == true else { return }
            revealTask(draft.id)
        default: break
        }
    }
    func completeReview(_ token: UUID) {
        guard token == routeToken else { return }
        acceptedWork = false; reconcile()
    }
    func timer(_ command: TimerCommand, after: (@MainActor () -> Void)? = nil) {
        guard acceptingMutations() else { return }
        let result = workspace.enqueueTimer(command)
        Task { do { _ = try await result.value; after?() } catch { failure = String(describing: error) } }
    }
    func undoMigration(receiptID: UUID) {
        guard acceptingMutations() else { return }
        finish(workspace.enqueueMigrationUndo(receiptID: receiptID))
    }
    func undoCorrection() {
        guard acceptingMutations() else { return }
        finish(workspace.enqueueCorrection(.undo))
    }
    func undoTimeReview() {
        guard acceptingMutations() else { return }
        finish(workspace.enqueueTimeReview(.undo))
    }
    private func finish(_ result: Task<LibrarySnapshot, Error>) {
        Task { @MainActor in do { _ = try await result.value } catch { failure = String(describing: error) } }
    }
    var ownedStop: TimerCommand? {
        switch workspace.timerStatus {
        case .running(let id): .stop(expectedEntryID: id)
        case .paused(let id): .stopAtCheckpoint(expectedEntryID: id)
        default: nil
        }
    }
    static func todayEntries(in snapshot: LibrarySnapshot, now: Date, calendar: Calendar) -> [TimeEntry] {
        TrackTotals.todayEntries(in: snapshot, now: now, calendar: calendar)
    }
}
extension TrackPresentation {
    private func present(_ route: TrackSheet) {
        guard sheet == nil, !acceptedWork else { feedback = "Finish or cancel the current editor first."; return }
        routeToken = UUID(); sheet = route
    }
    func editProject(_ id: UUID? = nil) {
        guard let snapshot = workspace.snapshot else { return }
        let project = snapshot.projects.first { $0.id == id }
        if id != nil && project == nil { failure = "Project no longer exists."; return }
        present(.project(ProjectDraft(id: project?.id ?? UUID(), isNew: project == nil,
            observedRevision: snapshot.revision,
            name: project?.name ?? "", rateText: project.map { RateInput.text($0.hourlyRate) } ?? "0",
            currencyCode: project?.currencyCode ?? "EUR", confirmedPreviousCurrency: nil, archiveConfirmed: false,
            reviewedSnapshot: snapshot)))
    }
    func newTask(projectID: UUID, parentID: UUID? = nil) {
        guard let snapshot = workspace.snapshot else { return }
        present(.task(TaskDraft(id: UUID(), isNew: true, observedRevision: snapshot.revision, projectID: projectID,
            parentID: parentID, name: "", migrationAccepted: false, budgetEnabled: false, budgetHours: "",
            originalBudgetMinutes: nil, originalBudgetText: "", reviewedSnapshot: snapshot)))
    }
    func editTask(_ id: UUID) {
        guard let snapshot = workspace.snapshot,
              let task = snapshot.tasks.first(where: { $0.id == id }) else { return }
        present(.task(taskDraft(task, snapshot: snapshot)))
    }
    private func taskDraft(_ task: TaskRecord, snapshot: LibrarySnapshot) -> TaskDraft {
        let text = task.budgetMinutes.map { BudgetInput.text($0) } ?? ""
        return TaskDraft(id: task.id, isNew: false, observedRevision: snapshot.revision, projectID: task.projectID,
            parentID: task.parentTaskID, name: task.name, migrationAccepted: false,
            budgetEnabled: task.budgetMinutes != nil,
            budgetHours: text, originalBudgetMinutes: task.budgetMinutes, originalBudgetText: text,
            reviewedSnapshot: snapshot)
    }
    func addTime(taskID: UUID? = nil) {
        present(.correction(CorrectionRoute(id: UUID(), mode: .add(taskID: taskID))))
    }
    func editTime(entryID: UUID) {
        guard let row = workspace.snapshot?.entries.first(where: { $0.id == entryID }) else {
            failure = "Entry no longer exists."
            return
        }
        guard row.endAt != nil else { reviewTime(); return }
        present(.correction(CorrectionRoute(id: UUID(), mode: .edit(entryID: entryID))))
    }
    func reviewTime() { present(.timeReview(UUID())) }
    func updateTaskDraft(_ draft: TaskDraft) {
        guard case .task(let current) = sheet, current.id == draft.id, !acceptedWork else { return }
        sheet = .task(draft)
    }
    func editConstrainingBudget(taskID: UUID) {
        guard case .task(let draft) = sheet, suspendedTaskDraft == nil, !acceptedWork,
              let snapshot = workspace.snapshot, let ancestor = snapshot.tasks.first(where: { $0.id == taskID }),
              ancestor.id != draft.id else { return }
        suspendedTaskDraft = draft; sheet = .task(taskDraft(ancestor, snapshot: snapshot)); routeToken = UUID()
    }
    func cancelSheet() {
        guard !acceptedWork else { return }
        if let draft = suspendedTaskDraft { suspendedTaskDraft = nil; sheet = .task(draft) } else { sheet = nil }
        routeToken = UUID()
    }
}
extension TrackPresentation {
    func projectTaskTotals() throws -> [TrackRowID: Int64] {
        guard let snapshot = workspace.snapshot else { throw LibraryAccessError.unavailable }
        let end = try workspace.trackLiveEnd()
        return try Self.projectTaskTotals(in: snapshot, liveEnd: end)
    }
    static func projectTaskTotals(in snapshot: LibrarySnapshot, liveEnd: Int64?) throws -> [TrackRowID: Int64] {
        try TrackTotals.projectTaskTotals(in: snapshot, liveEnd: liveEnd)
    }
}

extension TrackPresentation {
    func reconcile() {
        outlineCache = nil
        guard let snapshot = workspace.snapshot else { return }
        let projects = Set(snapshot.projects.map(\.id))
        let tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        if let id = selection.taskID, let task = tasks[id] {
            selection = Selection(projectID: task.projectID, taskID: id)
        } else {
            selection = Selection(projectID: selection.projectID.flatMap { projects.contains($0) ? $0 : nil },
                                  taskID: nil)
        }
        expandedProjectIDs.formIntersection(projects)
        expandedTaskIDs.formIntersection(Set(tasks.keys))
    }
    var projects: [Project] {
        (workspace.snapshot?.projects ?? []).filter { showArchived || !$0.isArchived }.sorted {
            let result = $0.name.localizedStandardCompare($1.name)
            return result == .orderedSame ? $0.id.uuidString < $1.id.uuidString : result == .orderedAscending
        }
    }
    func allRows(projectID: UUID) -> [TaskRow] {
        guard let snapshot = workspace.snapshot,
              let project = snapshot.projects.first(where: { $0.id == projectID }) else { return [] }
        let tasks = snapshot.tasks.filter { $0.projectID == projectID }
        let children = Dictionary(grouping: tasks, by: \.parentTaskID)
        func sorted(_ list: [TaskRecord]) -> [TaskRecord] {
            list.sorted {
                let result = $0.name.localizedStandardCompare($1.name)
                return result == .orderedSame ? $0.id.uuidString < $1.id.uuidString : result == .orderedAscending
            }
        }
        var stack = sorted(children[nil] ?? []).reversed().map { ($0, 0, project.name) }
        var result: [TaskRow] = [], visited = Set<UUID>()
        while let (task, depth, prefix) = stack.popLast() {
            guard visited.insert(task.id).inserted else { continue }
            let path = prefix + " / " + task.name
            let descendants = sorted(children[task.id] ?? [])
            result.append(TaskRow(task: task, depth: depth, path: path, isLeaf: descendants.isEmpty))
            for child in descendants.reversed() { stack.append((child, depth + 1, path)) }
        }
        return result
    }
    func rows(projectID: UUID) -> [TaskRow] {
        let all = allRows(projectID: projectID)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.task) })
        if !query.isEmpty {
            var included = Set(all.filter { $0.path.localizedStandardContains(query) }.map(\.id))
            for row in all where included.contains(row.id) {
                var parent = row.task.parentTaskID
                while let id = parent, let task = byID[id] {
                    included.insert(id); parent = task.parentTaskID
                }
            }
            return all.filter { included.contains($0.id) }
        }
        var hiddenDepth: Int?
        return all.filter { row in
            if let depth = hiddenDepth, row.depth > depth { return false }
            hiddenDepth = !row.isLeaf && !expandedTaskIDs.contains(row.id) ? row.depth : nil
            return true
        }
    }
    func path(_ id: UUID) -> String {
        guard let task = workspace.snapshot?.tasks.first(where: { $0.id == id }) else {
            return "Missing task (\(id))"
        }
        return allRows(projectID: task.projectID).first(where: { $0.id == id })?.path ?? id.uuidString
    }
    func eligible(_ id: UUID) -> Bool {
        guard let snapshot = workspace.snapshot, let task = snapshot.tasks.first(where: { $0.id == id }),
              snapshot.projects.contains(where: { $0.id == task.projectID && !$0.isArchived }) else { return false }
        return !snapshot.tasks.contains { $0.parentTaskID == id }
    }
}

extension TrackPresentation {
    func canStartFromList(_ id: UUID, listFocused: Bool) -> Bool {
        listFocused && selectedRow == .task(id) && eligible(id) && isVisible(.task(id))
    }
    func revealTask(_ id: UUID) {
        guard let task = workspace.snapshot?.tasks.first(where: { $0.id == id }) else {
            failure = "Task no longer exists: \(id)"
            return
        }
        destination = .track
        search = ""
        selectedRow = .task(id)
        expandedProjectIDs.insert(task.projectID)
        if workspace.snapshot?.projects.first(where: { $0.id == task.projectID })?.isArchived == true {
            showArchived = true
        }
        let byID = Dictionary(uniqueKeysWithValues: (workspace.snapshot?.tasks ?? []).map { ($0.id, $0) })
        var parent = task.parentTaskID, visited = Set<UUID>()
        while let parentID = parent, visited.insert(parentID).inserted {
            expandedTaskIDs.insert(parentID)
            parent = byID[parentID]?.parentTaskID
        }
        reveal = TaskReveal(id: UUID(), taskID: id)
    }
    func completeReveal(requestID: UUID) {
        guard let request = reveal, request.id == requestID, sheet == nil,
              destination == .track, selectedRow == .task(request.taskID) else { return }
        reveal = nil
    }
}
