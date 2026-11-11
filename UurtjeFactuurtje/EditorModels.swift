import Foundation
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
        case .project(let draft): draft.id
        case .task(let draft): draft.id
        case .correction(let route): route.id
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
    var reviewedSnapshot: LibrarySnapshot?
    func inputError(in snapshot: LibrarySnapshot) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a project name." }
        if name.contains("\0") { return "Remove the null character from the project name." }
        if !isNew && !snapshot.projects.contains(where: { $0.id == id }) {
            return "This project no longer exists."
        }
        if RateInput.parse(rateText) == nil { return "Enter a nonnegative decimal rate without grouping separators." }
        if !Locale.commonISOCurrencyCodes.contains(currencyCode) {
            return "Enter an uppercase ISO currency code, for example EUR or USD."
        }
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
    var reviewedSnapshot: LibrarySnapshot?
    var generatedBudgetMinutes: Int64?
    var generatedBudgetText: String?

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
            $0.id != id && $0.projectID == project && $0.parentTaskID == parent
                && NameKey.make($0.name) == NameKey.make(name)
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
    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}
