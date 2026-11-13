import Foundation
import LibraryStore
import Observation

enum ReportMode: String, CaseIterable { case week, project }

struct WeekReturnContext {
    let anchor: Int64?
    let includeArchived: Bool
}

@MainActor @Observable final class ReportsPresentation {
    let track: TrackPresentation
    var mode: ReportMode = .week
    var weekAnchor: Int64?
    var includeArchived = false
    var selectedProjectID: UUID?
    private(set) var scopeTaskID: UUID?
    var period: ReportPeriod = .allTime
    var expandedTaskIDs: Set<UUID> = []
    var selectedLeafID: UUID?
    var selectedEntryID: UUID?
    private(set) var returnToWeek: WeekReturnContext?
    private(set) var week: WeeklyReport?
    private(set) var project: ProjectReport?
    private(set) var weeklyAmounts: [CurrencyAmount] = []
    private(set) var taskAmounts: [UUID: CurrencyAmount] = [:]
    private(set) var entryAmounts: [UUID: CurrencyAmount] = [:]
    private(set) var projectAmount: CurrencyAmount?
    private(set) var error: String?
    private(set) var calendar = Calendar.current

    init(track: TrackPresentation) { self.track = track }

    var visibleProjects: [Project] {
        (track.workspace.snapshot?.projects ?? [])
            .filter { includeArchived || !$0.isArchived }
            .sorted {
                $0.name == $1.name
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    func moveWeek(_ offset: Int, now: Int64, calendar: Calendar) throws {
        let anchor = Date(timeIntervalSince1970: TimeInterval(weekAnchor ?? now))
        guard let next = calendar.date(byAdding: .weekOfYear, value: offset, to: anchor) else {
            throw ReportError.invalidDate
        }
        weekAnchor = Int64(next.timeIntervalSince1970.rounded(.down))
    }

    func showThisWeek() { weekAnchor = nil }

    func openProject(_ projectID: UUID, scopeTaskID: UUID? = nil) {
        guard let snapshot = track.workspace.snapshot,
            snapshot.projects.contains(where: { $0.id == projectID }),
            scopeTaskID == nil
                || snapshot.tasks.contains(where: {
                    $0.id == scopeTaskID && $0.projectID == projectID
                })
        else { return }
        if mode == .week {
            returnToWeek = WeekReturnContext(anchor: weekAnchor, includeArchived: includeArchived)
        }
        if snapshot.projects.contains(where: { $0.id == projectID && $0.isArchived }) {
            includeArchived = true
        }
        if selectedProjectID != projectID || self.scopeTaskID != scopeTaskID {
            selectedProjectID = projectID
            self.scopeTaskID = scopeTaskID
            period = .allTime
            expandedTaskIDs = []
            selectedLeafID = nil
            selectedEntryID = nil
            project = nil
            taskAmounts = [:]
            entryAmounts = [:]
            projectAmount = nil
        }
        mode = .project
    }

    func clearTaskFilter() {
        scopeTaskID = nil
        expandedTaskIDs = []
        selectedLeafID = nil
        selectedEntryID = nil
        project = nil
        taskAmounts = [:]
        entryAmounts = [:]
        projectAmount = nil
    }

    func openDay(projectID: UUID, day: WeeklyReportDay) {
        guard let start = day.bounds?.start, visibleProjects.contains(where: { $0.id == projectID }) else { return }
        openProject(projectID)
        period = .day(containing: start)
    }

    func backToWeek() {
        if let context = returnToWeek {
            weekAnchor = context.anchor
            includeArchived = context.includeArchived
        }
        mode = .week
        returnToWeek = nil
    }

    func weeklyReport(now: Int64, calendar: Calendar, firstWeekday: Int) throws -> WeeklyReport {
        try track.workspace.weeklyReport(
            containing: weekAnchor ?? now, calendar: calendar,
            firstWeekday: firstWeekday, includeArchived: includeArchived)
    }

    func projectReport(calendar: Calendar, firstWeekday: Int) throws -> ProjectReport? {
        guard let id = selectedProjectID else { return nil }
        return try track.workspace.projectReport(
            id, period: period, calendar: calendar,
            firstWeekday: firstWeekday, scopeTaskID: scopeTaskID)
    }

    private func clearResults() {
        week = nil
        project = nil
        weeklyAmounts = []
        taskAmounts = [:]
        entryAmounts = [:]
        projectAmount = nil
    }

    func refresh(now: Int64, calendar: Calendar) {
        self.calendar = calendar
        error = nil
        guard track.workspace.availability == .ready || track.workspace.availability == .reviewRequired,
            track.workspace.snapshot != nil
        else {
            clearResults()
            error = "Library unavailable. Open or recover the library to view reports."
            return
        }
        guard let weekday = track.workspace.firstWeekday else {
            clearResults()
            error = "Week start is unavailable. Wait for settings or reopen the library."
            return
        }
        guard (1...7).contains(weekday) else {
            clearResults()
            error = "Invalid confirmed week start: \(weekday)."
            return
        }
        self.calendar.firstWeekday = weekday
        if let id = selectedProjectID, !visibleProjects.contains(where: { $0.id == id }) {
            selectedProjectID = nil
            scopeTaskID = nil
            expandedTaskIDs = []
            selectedLeafID = nil
            selectedEntryID = nil
            period = .allTime
        }
        do {
            if mode == .week {
                try refreshWeekly(now: now, calendar: calendar, firstWeekday: weekday)
            } else if let value = try projectReport(calendar: calendar, firstWeekday: weekday) {
                try applyProjectReport(value)
            } else {
                clearProjectResults()
            }
        } catch {
            clearResults()
            self.error = "Report unavailable: \(error)"
        }
    }

    private func refreshWeekly(now: Int64, calendar: Calendar, firstWeekday: Int) throws {
        let value = try weeklyReport(now: now, calendar: calendar, firstWeekday: firstWeekday)
        let amounts = try ReportProjection.amounts(
            totals: value.projectTotals,
            projects: value.projects,
        )
        week = value
        weeklyAmounts = amounts
    }

    private func clearProjectResults() {
        project = nil
        taskAmounts = [:]
        entryAmounts = [:]
        projectAmount = nil
    }

    private func applyProjectReport(_ value: ProjectReport) throws {
        var taskAmounts: [UUID: CurrencyAmount] = [:]
        var entryAmounts: [UUID: CurrencyAmount] = [:]
        for task in value.tasks {
            let seconds = value.taskTotals[task.id]?.totalSeconds ?? 0
            taskAmounts[task.id] = try ReportProjection.amount(
                seconds: seconds,
                project: value.project,
            )
        }
        for rows in value.entriesByLeaf.values {
            for row in rows {
                entryAmounts[row.id] = try ReportProjection.amount(
                    seconds: row.seconds,
                    project: value.project,
                )
            }
        }
        projectAmount = try ReportProjection.amount(
            seconds: value.total.totalSeconds,
            project: value.project,
        )
        reconcileProjectSelection(in: value)
        project = value
        self.taskAmounts = taskAmounts
        self.entryAmounts = entryAmounts
    }

    private func reconcileProjectSelection(in value: ProjectReport) {
        let ids = Set(value.tasks.map(\.id))
        expandedTaskIDs.formIntersection(ids)
        if let leaf = selectedLeafID,
            !ids.contains(leaf) || value.tasks.contains(where: { $0.parentTaskID == leaf }) {
            selectedLeafID = nil
            selectedEntryID = nil
        }
        let entries = value.entriesByLeaf[selectedLeafID ?? UUID()] ?? []
        if let entry = selectedEntryID,
            !entries.contains(where: { $0.id == entry }) {
            selectedEntryID = nil
        }
    }

    func applyCustom(first: DateComponents, last: DateComponents) {
        period = .custom(first: first, last: last)
    }

    func addTime(taskID: UUID) { track.addTime(taskID: taskID) }

    func editEntry(_ row: ReportEntryRow) {
        guard row.entry.endAt != nil else { return }
        selectedEntryID = row.entry.id
        track.editTime(entryID: row.entry.id)
    }

    func reviewTime() { track.reviewTime() }

    func restoreProject(_ id: UUID) { track.editProject(id) }

    func openLabel(entryID: UUID?) -> String {
        if case .running(let id) = track.workspace.timerStatus, entryID == id {
            return "Provisional, live when authorized; otherwise checkpoint only"
        }
        return "Provisional, saved checkpoint only"
    }
}
