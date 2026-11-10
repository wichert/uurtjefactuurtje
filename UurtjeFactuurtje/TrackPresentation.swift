import Foundation
import Observation
import LibraryStore

enum WorkspaceDestination: String { case track, reports }
enum TrackRowID: Hashable, Sendable {
    case project(UUID)
    case task(UUID)
}

struct TrackOutlineRow: Identifiable, Equatable {
    let id: TrackRowID
    let projectID: UUID
    let title: String
    let path: String
    let isArchived: Bool
    let isLeafTask: Bool
    let children: [TrackOutlineRow]
}
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
    let originalBudgetMinutes: Int64?
    let originalBudgetText: String
    var reviewedSnapshot: LibrarySnapshot? = nil
    var generatedBudgetMinutes: Int64? = nil
    var generatedBudgetText: String? = nil

    var parsedBudget: Int64? { budgetValue() }

    func budgetValue(locale: Locale = .current) -> Int64? {
        guard budgetEnabled else { return nil }
        let value: Int64?
        if budgetHours == generatedBudgetText, let generatedBudgetMinutes {
            value = generatedBudgetMinutes
        } else if budgetHours == originalBudgetText, let originalBudgetMinutes {
            value = originalBudgetMinutes
        } else {
            value = BudgetInput.parseHours(budgetHours, locale: locale)
        }
        guard let value, value > 0 else { return nil }
        return value
    }

    func budgetAfterStep(by minutes: Int64, locale: Locale = .current) -> Int64? {
        guard budgetEnabled else { return nil }
        let value: Int64
        if budgetHours.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value = 0
        } else {
            guard let parsed = budgetValue(locale: locale) else { return nil }
            value = parsed
        }
        let (next, overflow) = value.addingReportingOverflow(minutes)
        return !overflow && next > 0 ? next : nil
    }

    mutating func stepBudget(by minutes: Int64, locale: Locale = .current) {
        guard let next = budgetAfterStep(by: minutes, locale: locale) else { return }
        let text = BudgetInput.text(next, locale: locale)
        generatedBudgetMinutes = next
        generatedBudgetText = text
        budgetHours = text
    }

    func inputError(in snapshot: LibrarySnapshot) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a task name." }
        if name.contains("\0") { return "Remove the null character from the task name." }
        let existing = snapshot.tasks.first { $0.id == id }
        if !isNew && existing == nil { return "This task no longer exists." }
        let project = isNew ? projectID : existing!.projectID
        let parent = isNew ? parentID : existing!.parentTaskID
        if isNew {
            guard snapshot.projects.contains(where: { $0.id == project && !$0.isArchived }) else {
                return "This project is unavailable for new tasks. Cancel and select an active project."
            }
            if let parent, !snapshot.tasks.contains(where: { $0.id == parent && $0.projectID == project }) {
                return "This parent is unavailable. Cancel and select a task in this project."
            }
        }
        if snapshot.tasks.contains(where: {
            $0.id != id && $0.projectID == project && $0.parentTaskID == parent && NameKey.make($0.name) == NameKey.make(name)
        }) { return "A task with this name already exists under this parent. Choose a different name." }
        if budgetEnabled && parsedBudget == nil {
            return "Enter positive budget hours that represent a whole number of minutes."
        }
        return nil
    }
    mutating func relocate(projectID: UUID, parentID: UUID?) {
        if self.projectID != projectID || self.parentID != parentID { migrationAccepted = false }
        self.projectID = projectID; self.parentID = parentID
    }
    func request(start: Bool) -> TaskCreationRequest {
        TaskCreationRequest(id: id, projectID: projectID, parentID: parentID,
                            name: name, budgetMinutes: parsedBudget,
                            confirmMigration: migrationAccepted, start: start)
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

private struct OutlineCacheKey: Equatable {
    let revision: Int64
    let showArchived: Bool
    let search: String
    let localeIdentifier: String
}

@MainActor @Observable final class TrackPresentation {
    @ObservationIgnored private var outlineCache: (key: OutlineCacheKey, rows: [TrackOutlineRow])?

    func outlineRows() -> [TrackOutlineRow] {
        guard let s = workspace.snapshot else { outlineCache = nil; return [] }
        let key = OutlineCacheKey(revision: s.revision, showArchived: showArchived,
                                  search: search, localeIdentifier: Locale.current.identifier)
        if let outlineCache, outlineCache.key == key { return outlineCache.rows }
        let visibleProjects = projects
        let projectIDs = Set(visibleProjects.map(\.id))
        let tasks = s.tasks.filter { projectIDs.contains($0.projectID) }
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
        var result: [TrackOutlineRow] = []
        for project in visibleProjects {
            let projectRoots = ordered(roots[project.id] ?? [])
            let projectMatches = query.isEmpty || project.name.localizedStandardContains(query)
            var stack = projectRoots.reversed().map { ($0, project.name, projectMatches) }
            var preorder: [(task: TaskRecord, path: String, childIDs: [UUID], included: Bool)] = []
            var visited = Set<UUID>()
            while let (task, prefix, ancestorMatches) = stack.popLast() {
                guard visited.insert(task.id).inserted else { continue }
                let path = prefix + " / " + task.name
                let descendants = ordered(children[task.id] ?? [])
                preorder.append((task, path, descendants.map(\.id), ancestorMatches))
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
            guard query.isEmpty || project.name.localizedStandardContains(query) || !nested.isEmpty else { continue }
            result.append(TrackOutlineRow(id: .project(project.id), projectID: project.id,
                title: project.name, path: project.name, isArchived: project.isArchived,
                isLeafTask: false, children: nested))
        }
        outlineCache = (key, result)
        return result
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

    func projectTaskTotals() throws -> [TrackRowID: Int64] {
        guard let snapshot = workspace.snapshot else { throw LibraryAccessError.unavailable }
        let end = try workspace.trackLiveEnd()
        return try Self.projectTaskTotals(in: snapshot, liveEnd: end)
    }

    static func projectTaskTotals(in s: LibrarySnapshot, liveEnd: Int64?) throws -> [TrackRowID: Int64] {
        func adding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            guard !overflow else { throw ReportError.intervalOverflow }
            return value
        }
        var totals: [TrackRowID: Int64] = [:]
        for project in s.projects {
            guard totals.updateValue(0, forKey: .project(project.id)) == nil else {
                throw ReportError.invalidHierarchy
            }
        }
        var tasks: [UUID: TaskRecord] = [:]
        for task in s.tasks {
            guard totals[.project(task.projectID)] != nil,
                  tasks.updateValue(task, forKey: task.id) == nil else { throw ReportError.invalidHierarchy }
            totals[.task(task.id)] = 0
        }
        var remaining: [UUID: Int] = [:]
        for task in s.tasks {
            if let parent = task.parentTaskID {
                guard let owner = tasks[parent], owner.projectID == task.projectID else {
                    throw ReportError.invalidHierarchy
                }
                remaining[parent, default: 0] += 1
            }
        }
        var bottomUp = s.tasks.filter { remaining[$0.id] == nil }.map(\.id)
        var index = 0
        while index < bottomUp.count {
            if let parent = tasks[bottomUp[index]]?.parentTaskID {
                remaining[parent, default: 0] -= 1
                if remaining[parent] == 0 { bottomUp.append(parent) }
            }
            index += 1
        }
        guard bottomUp.count == s.tasks.count else { throw ReportError.invalidHierarchy }
        // remaining is now zeroed; keep structural leaf identity independently for entry checks.
        let parentIDs = Set(s.tasks.compactMap(\.parentTaskID))
        var seenEntries = Set<UUID>()
        var foundActive = false
        for entry in s.entries {
            guard seenEntries.insert(entry.id).inserted,
                  tasks[entry.taskID] != nil, !parentIDs.contains(entry.taskID) else {
                throw ReportError.invalidHierarchy
            }
            let end: Int64
            if let closed = entry.endAt {
                guard entry.id != s.activeTimer?.entryID else { throw ReportError.invalidActiveEntry }
                end = closed
            } else {
                guard let active = s.activeTimer, active.entryID == entry.id, !foundActive,
                      active.checkpointAt >= entry.startAt,
                      liveEnd == nil || liveEnd! >= active.checkpointAt else {
                    throw ReportError.invalidActiveEntry
                }
                foundActive = true
                end = liveEnd ?? active.checkpointAt
            }
            let (seconds, overflow) = end.subtractingReportingOverflow(entry.startAt)
            guard !overflow, seconds >= 0, seconds != 0 || entry.endAt == nil else {
                throw ReportError.intervalOverflow
            }
            totals[.task(entry.taskID)] = try adding(totals[.task(entry.taskID), default: 0], seconds)
        }
        guard (s.activeTimer != nil) == foundActive else { throw ReportError.invalidActiveEntry }
        for id in bottomUp {
            guard let task = tasks[id] else { throw ReportError.invalidHierarchy }
            let destination: TrackRowID = task.parentTaskID.map { .task($0) } ?? .project(task.projectID)
            totals[destination] = try adding(totals[destination, default: 0], totals[.task(id), default: 0])
        }
        return totals
    }

    let workspace: WorkspaceModel
    private let defaults: UserDefaults
    var destination: WorkspaceDestination = .track
    private struct Selection {
        var projectID: UUID?
        var taskID: UUID?
    }
    private var selection: Selection { didSet { persist() } }

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

    private func persist() {
        defaults.set(selection.projectID?.uuidString, forKey: "track.project")
        defaults.set(selection.taskID?.uuidString, forKey: "track.task")
        defaults.set(expandedProjectIDs.map(\.uuidString).sorted(), forKey: "track.expandedProjects")
        defaults.set(expandedTaskIDs.map(\.uuidString).sorted(), forKey: "track.expanded")
    }

    func reconcile() {
        outlineCache = nil
        guard let s = workspace.snapshot else { return }
        let projects = Set(s.projects.map(\.id))
        let tasks = Dictionary(uniqueKeysWithValues: s.tasks.map { ($0.id, $0) })
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
        listFocused && selectedRow == .task(id) && eligible(id) && isVisible(.task(id))
    }
    func revealTask(_ id: UUID) {
        guard let task = workspace.snapshot?.tasks.first(where: { $0.id == id }) else { failure = "Task no longer exists: \(id)"; return }
        destination = .track
        search = ""
        selectedRow = .task(id)
        expandedProjectIDs.insert(task.projectID)
        if workspace.snapshot?.projects.first(where: { $0.id == task.projectID })?.isArchived == true { showArchived = true }
        let byID = Dictionary(uniqueKeysWithValues: (workspace.snapshot?.tasks ?? []).map { ($0.id, $0) })
        var parent = task.parentTaskID, visited = Set<UUID>()
        while let p = parent, visited.insert(p).inserted {
            expandedTaskIDs.insert(p); parent = byID[p]?.parentTaskID
        }
        reveal = TaskReveal(id: UUID(), taskID: id)
    }
    func completeReveal(requestID: UUID) {
        guard let request = reveal, request.id == requestID, sheet == nil,
              destination == .track, selectedRow == .task(request.taskID) else { return }
        reveal = nil
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
            originalBudgetMinutes: nil, originalBudgetText: "", reviewedSnapshot: s)))
    }
    func editTask(_ id: UUID) {
        guard let s = workspace.snapshot, let t = s.tasks.first(where: { $0.id == id }) else { return }
        present(.task(taskDraft(t, snapshot: s)))
    }
    private func taskDraft(_ t: TaskRecord, snapshot s: LibrarySnapshot) -> TaskDraft {
        let text = t.budgetMinutes.map { BudgetInput.text($0) } ?? ""
        return TaskDraft(id: t.id, isNew: false, observedRevision: s.revision, projectID: t.projectID,
            parentID: t.parentTaskID, name: t.name, migrationAccepted: false, budgetEnabled: t.budgetMinutes != nil,
            budgetHours: text, originalBudgetMinutes: t.budgetMinutes, originalBudgetText: text,
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
    static func todayEntries(in s: LibrarySnapshot, now: Date, calendar: Calendar) -> [TimeEntry] {
        guard let day = calendar.dateInterval(of: .day, for: now) else { return [] }
        let lo = Int64(day.start.timeIntervalSince1970), hi = Int64(day.end.timeIntervalSince1970)
        return s.entries.filter { e in
            if let end = e.endAt { return e.startAt < hi && end > lo }
            return e.startAt >= lo && e.startAt < hi || (s.activeTimer?.entryID == e.id && (s.activeTimer?.checkpointAt ?? e.startAt) > lo && e.startAt < hi)
        }.sorted { $0.startAt == $1.startAt ? $0.id.uuidString < $1.id.uuidString : $0.startAt < $1.startAt }
    }
}
