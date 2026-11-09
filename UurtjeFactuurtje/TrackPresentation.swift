import Foundation
import Observation
import LibraryStore

enum WorkspaceDestination: String { case track, reports }
struct TaskRow: Identifiable {
    let task: TaskRecord
    let depth: Int
    let path: String
    let isLeaf: Bool
    var id: UUID { task.id }
}
struct TaskReveal: Identifiable { let id: UUID; let taskID: UUID }
enum TrackSheet: Identifiable {
    case project(ProjectDraft), task(TaskDraft), correction(CorrectionRoute), timeReview(UUID)
    var id: UUID {
        switch self {
        case .project(let d): d.id
        case .task(let d): d.id
        case .correction(let r): r.id
        case .timeReview(let id): id
        }
    }
}
struct ProjectDraft: Identifiable {
    let id: UUID
    let isNew: Bool
    let observedRevision: Int64
    var name: String
    var rateText: String
    var currencyCode: String
    var confirmedPreviousCurrency: String?
    var archiveConfirmed: Bool
    var reviewedSnapshot: LibrarySnapshot? = nil
    func inputError(in snapshot: LibrarySnapshot) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a project name." }
        if name.contains("\0") { return "Remove the null character from the project name." }
        if !isNew && !snapshot.projects.contains(where: { $0.id == id }) { return "This project no longer exists." }
        if RateInput.parse(rateText) == nil { return "Enter a nonnegative decimal rate without grouping separators." }
        if !Locale.commonISOCurrencyCodes.contains(currencyCode) { return "Enter an uppercase ISO currency code, for example EUR or USD." }
        return nil
    }
}
struct TaskDraft: Identifiable {
    let id: UUID
    let isNew: Bool
    var observedRevision: Int64
    var projectID: UUID
    var parentID: UUID?
    var name: String
    var migrationAccepted: Bool
    var budgetEnabled: Bool
    var budgetHours: String
    let originalBudgetSeconds: Int64?
    let originalBudgetText: String
    var reviewedSnapshot: LibrarySnapshot? = nil
    var parsedBudget: Int64? {
        guard budgetEnabled else { return nil }
        return budgetHours == originalBudgetText ? originalBudgetSeconds : BudgetInput.parseHours(budgetHours)
    }
    func inputError(in snapshot: LibrarySnapshot) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a task name." }
        if name.contains("\0") { return "Remove the null character from the task name." }
        let existing = snapshot.tasks.first { $0.id == id }
        if !isNew && existing == nil { return "This task no longer exists." }
        let project = isNew ? projectID : existing!.projectID
        let parent = isNew ? parentID : existing!.parentTaskID
        if snapshot.tasks.contains(where: {
            $0.id != id && $0.projectID == project && $0.parentTaskID == parent && NameKey.make($0.name) == NameKey.make(name)
        }) { return "A task with this name already exists under this parent. Choose a different name." }
        return nil
    }
    mutating func relocate(projectID: UUID, parentID: UUID?) {
        if self.projectID != projectID || self.parentID != parentID { migrationAccepted = false }
        self.projectID = projectID; self.parentID = parentID
    }
    func request(start: Bool) -> TaskCreationRequest {
        TaskCreationRequest(id: id, projectID: projectID, parentID: parentID,
                            name: name, confirmMigration: migrationAccepted, start: start)
    }
}
struct CorrectionRoute: Identifiable {
    enum Mode { case add(taskID: UUID?), edit(entryID: UUID) }
    let id: UUID
    let mode: Mode
}
enum EditorError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}

@MainActor @Observable final class TrackPresentation {
    let workspace: WorkspaceModel
    private let defaults: UserDefaults
    var destination: WorkspaceDestination = .track
    var selectedProjectID: UUID? { didSet { persist() } }
    var selectedTaskID: UUID? { didSet { persist() } }
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
        self.workspace = workspace; self.defaults = defaults
        selectedProjectID = defaults.string(forKey: "track.project").flatMap(UUID.init(uuidString:))
        selectedTaskID = defaults.string(forKey: "track.task").flatMap(UUID.init(uuidString:))
        expandedTaskIDs = Set((defaults.stringArray(forKey: "track.expanded") ?? []).compactMap(UUID.init(uuidString:)))
    }
    private func persist() {
        defaults.set(selectedProjectID?.uuidString, forKey: "track.project")
        defaults.set(selectedTaskID?.uuidString, forKey: "track.task")
        defaults.set(expandedTaskIDs.map(\.uuidString).sorted(), forKey: "track.expanded")
    }
    func reconcile() {
        guard let s = workspace.snapshot else { return }
        let projects = Set(s.projects.map(\.id)), tasks = Set(s.tasks.map(\.id))
        if let id = selectedProjectID, !projects.contains(id) { selectedProjectID = nil }
        if let id = selectedTaskID, !tasks.contains(id) { selectedTaskID = nil }
        expandedTaskIDs.formIntersection(tasks)
    }
    var projects: [Project] {
        (workspace.snapshot?.projects ?? []).filter { showArchived || !$0.isArchived }.sorted {
            let result = $0.name.localizedStandardCompare($1.name)
            return result == .orderedSame ? $0.id.uuidString < $1.id.uuidString : result == .orderedAscending
        }
    }
    func allRows(projectID: UUID) -> [TaskRow] {
        guard let s = workspace.snapshot, let project = s.projects.first(where: { $0.id == projectID }) else { return [] }
        let tasks = s.tasks.filter { $0.projectID == projectID }
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
        guard let task = workspace.snapshot?.tasks.first(where: { $0.id == id }) else { return "Missing task (\(id))" }
        return allRows(projectID: task.projectID).first(where: { $0.id == id })?.path ?? id.uuidString
    }
    func eligible(_ id: UUID) -> Bool {
        guard let s = workspace.snapshot, let task = s.tasks.first(where: { $0.id == id }),
              s.projects.contains(where: { $0.id == task.projectID && !$0.isArchived }) else { return false }
        return !s.tasks.contains { $0.parentTaskID == id }
    }
    func canStartFromList(_ id: UUID, listFocused: Bool) -> Bool {
        guard listFocused, selectedProjectID != nil, let project = projects.first(where: { $0.id == selectedProjectID }) else { return false }
        return eligible(id) && rows(projectID: project.id).contains { $0.id == id && $0.isLeaf }
    }
    func revealTask(_ id: UUID) {
        guard let task = workspace.snapshot?.tasks.first(where: { $0.id == id }) else { failure = "Task no longer exists: \(id)"; return }
        destination = .track; search = ""; selectedProjectID = task.projectID; selectedTaskID = id
        if workspace.snapshot?.projects.first(where: { $0.id == task.projectID })?.isArchived == true { showArchived = true }
        let byID = Dictionary(uniqueKeysWithValues: (workspace.snapshot?.tasks ?? []).map { ($0.id, $0) })
        var parent = task.parentTaskID, visited = Set<UUID>()
        while let p = parent, visited.insert(p).inserted {
            expandedTaskIDs.insert(p); parent = byID[p]?.parentTaskID
        }
        reveal = TaskReveal(id: UUID(), taskID: id)
    }
    func consumeReveal() -> TaskReveal? {
        guard sheet == nil, destination == .track, let request = reveal,
              let projectID = selectedProjectID,
              projects.contains(where: { $0.id == projectID }),
              rows(projectID: projectID).contains(where: { $0.id == request.taskID }) else { return nil }
        reveal = nil
        return request
    }
    private func present(_ route: TrackSheet) {
        guard sheet == nil, !acceptedWork else { feedback = "Finish or cancel the current editor first."; return }
        routeToken = UUID(); sheet = route
    }
    func editProject(_ id: UUID? = nil) {
        guard let s = workspace.snapshot else { return }
        let p = s.projects.first { $0.id == id }
        if id != nil && p == nil { failure = "Project no longer exists."; return }
        present(.project(ProjectDraft(id: p?.id ?? UUID(), isNew: p == nil, observedRevision: s.revision,
            name: p?.name ?? "", rateText: p.map { RateInput.text($0.hourlyRate) } ?? "0",
            currencyCode: p?.currencyCode ?? "EUR", confirmedPreviousCurrency: nil, archiveConfirmed: false,
            reviewedSnapshot: s)))
    }
    func newTask(projectID: UUID, parentID: UUID? = nil) {
        guard let s = workspace.snapshot else { return }
        present(.task(TaskDraft(id: UUID(), isNew: true, observedRevision: s.revision, projectID: projectID,
            parentID: parentID, name: "", migrationAccepted: false, budgetEnabled: false, budgetHours: "",
            originalBudgetSeconds: nil, originalBudgetText: "", reviewedSnapshot: s)))
    }
    func editTask(_ id: UUID) {
        guard let s = workspace.snapshot, let t = s.tasks.first(where: { $0.id == id }) else { return }
        present(.task(taskDraft(t, snapshot: s)))
    }
    private func taskDraft(_ t: TaskRecord, snapshot s: LibrarySnapshot) -> TaskDraft {
        let text = t.budgetSeconds.map { BudgetInput.text($0) } ?? ""
        return TaskDraft(id: t.id, isNew: false, observedRevision: s.revision, projectID: t.projectID,
            parentID: t.parentTaskID, name: t.name, migrationAccepted: false, budgetEnabled: t.budgetSeconds != nil,
            budgetHours: text, originalBudgetSeconds: t.budgetSeconds, originalBudgetText: text,
            reviewedSnapshot: s)
    }
    func addTime(taskID: UUID? = nil) { present(.correction(CorrectionRoute(id: UUID(), mode: .add(taskID: taskID)))) }
    func editTime(entryID: UUID) {
        guard let row = workspace.snapshot?.entries.first(where: { $0.id == entryID }) else { failure = "Entry no longer exists."; return }
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
              let s = workspace.snapshot, let ancestor = s.tasks.first(where: { $0.id == taskID }), ancestor.id != draft.id else { return }
        suspendedTaskDraft = draft; sheet = .task(taskDraft(ancestor, snapshot: s)); routeToken = UUID()
    }
    func cancelSheet() {
        guard !acceptedWork else { return }
        if let draft = suspendedTaskDraft { suspendedTaskDraft = nil; sheet = .task(draft) }
        else { sheet = nil }
        routeToken = UUID()
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
            selectedProjectID = project.id
            selectedTaskID = nil
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
    static func todayEntries(in s: LibrarySnapshot, now: Date, calendar: Calendar) -> [TimeEntry] {
        guard let day = calendar.dateInterval(of: .day, for: now) else { return [] }
        let lo = Int64(day.start.timeIntervalSince1970), hi = Int64(day.end.timeIntervalSince1970)
        return s.entries.filter { e in
            if let end = e.endAt { return e.startAt < hi && end > lo }
            return e.startAt >= lo && e.startAt < hi || (s.activeTimer?.entryID == e.id && (s.activeTimer?.checkpointAt ?? e.startAt) > lo && e.startAt < hi)
        }.sorted { $0.startAt == $1.startAt ? $0.id.uuidString < $1.id.uuidString : $0.startAt < $1.startAt }
    }
}
