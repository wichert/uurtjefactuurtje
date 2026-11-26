import Foundation
import LibraryStore
import Observation
import SwiftUI

enum ReportMode: String, CaseIterable {
    case week
    case project

    static var timesheets: ReportMode { .project }
}

struct WeekReturnContext {
    let anchor: Int64?
    let includeArchived: Bool
}

enum ProjectAccentStyle: Int, Equatable, Sendable {
    case solid = 0
    case dashed = 1
    case doubleBar = 2
    case dotted = 3

    var markerSymbol: String {
        switch self {
        case .solid: return "●"
        case .dashed: return "◆"
        case .doubleBar: return "▲"
        case .dotted: return "■"
        }
    }
}

struct ProjectColorSpace: Equatable, Sendable {
    let familyIndex: Int
    let hueStart: Double
    let hueEnd: Double
    let saturationStart: Double
    let saturationEnd: Double
    let brightnessStart: Double
    let brightnessEnd: Double
    let accentStyle: ProjectAccentStyle

    static func forProjectIndex(_ index: Int) -> ProjectColorSpace {
        switch index {
        case 0:
            // Project 1 — Ocean Blue
            return ProjectColorSpace(
                familyIndex: 0,
                hueStart: 218.0, hueEnd: 202.0,
                saturationStart: 0.85, saturationEnd: 0.42,
                brightnessStart: 0.46, brightnessEnd: 0.94,
                accentStyle: .solid
            )
        case 1:
            // Project 2 — Warm Amber / Vermilion
            return ProjectColorSpace(
                familyIndex: 1,
                hueStart: 18.0, hueEnd: 42.0,
                saturationStart: 0.92, saturationEnd: 0.50,
                brightnessStart: 0.52, brightnessEnd: 0.96,
                accentStyle: .dashed
            )
        case 2:
            // Project 3 — Plum / Magenta-Violet
            return ProjectColorSpace(
                familyIndex: 2,
                hueStart: 316.0, hueEnd: 336.0,
                saturationStart: 0.82, saturationEnd: 0.38,
                brightnessStart: 0.44, brightnessEnd: 0.92,
                accentStyle: .doubleBar
            )
        default:
            let step = Double(max(0, index - 2)) * 137.508
            let center = (336.0 + step).truncatingRemainder(dividingBy: 360.0)
            return ProjectColorSpace(
                familyIndex: index,
                hueStart: center - 10.0, hueEnd: center + 10.0,
                saturationStart: 0.84, saturationEnd: 0.42,
                brightnessStart: 0.46, brightnessEnd: 0.94,
                accentStyle: .dotted
            )
        }
    }

    func normalizedHue(at ratio: Double) -> Double {
        let clamped = min(1.0, max(0.0, ratio))
        let raw = (hueStart + clamped * (hueEnd - hueStart)).truncatingRemainder(dividingBy: 360.0)
        return (raw < 0 ? raw + 360.0 : raw) / 360.0
    }

    func saturation(at ratio: Double) -> Double {
        let clamped = min(1.0, max(0.0, ratio))
        return saturationStart + clamped * (saturationEnd - saturationStart)
    }

    func brightness(at ratio: Double) -> Double {
        let clamped = min(1.0, max(0.0, ratio))
        return brightnessStart + clamped * (brightnessEnd - brightnessStart)
    }

    func color(taskIndex: Int, taskCount: Int) -> (hue: Double, saturation: Double, brightness: Double) {
        let ratio: Double
        if taskCount <= 1 {
            ratio = 0.45
        } else {
            let clampedIndex = min(max(0, taskIndex), taskCount - 1)
            ratio = Double(clampedIndex) / Double(taskCount - 1)
        }
        return (normalizedHue(at: ratio), saturation(at: ratio), brightness(at: ratio))
    }
}

struct BlockVisualStyle: Equatable, Sendable {
    let projectFamilyIndex: Int
    let taskIndex: Int
    let taskCount: Int
    let hue: Double
    let saturation: Double
    let brightness: Double
    let accentHue: Double
    let accentSaturation: Double
    let accentBrightness: Double
    let accentStyle: ProjectAccentStyle

    var fillColor: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    var accentColor: Color {
        Color(hue: accentHue, saturation: accentSaturation, brightness: accentBrightness)
    }

    var markerSymbol: String {
        accentStyle.markerSymbol
    }
}

struct ProjectLegendItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let familyIndex: Int
    let swatchHue: Double
    let swatchSaturation: Double
    let swatchBrightness: Double
    let accentStyle: ProjectAccentStyle

    var swatchColor: Color {
        Color(hue: swatchHue, saturation: swatchSaturation, brightness: swatchBrightness)
    }

    var markerSymbol: String {
        accentStyle.markerSymbol
    }
}

struct WeekTimeBlock: Identifiable, Equatable, Sendable {
    let id: String
    let entryID: UUID
    let dayIndex: Int
    let projectID: UUID
    let taskID: UUID
    let projectName: String
    let taskName: String
    let startAt: Int64
    let endAt: Int64
    let durationSeconds: Int64
    let startMinuteOfDay: Double
    let endMinuteOfDay: Double
    let style: BlockVisualStyle
    let isEditable: Bool
}

struct TimesheetRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let entry: TimeEntry
    let startAt: Int64
    let endAt: Int64
    let durationSeconds: Int64
    let projectID: UUID
    let projectName: String
    let taskID: UUID
    let taskName: String
    let isEditable: Bool
}

struct TaskFilterOption: Identifiable, Equatable, Sendable {
    let id: UUID
    let projectID: UUID
    let title: String
}

@MainActor @Observable final class ReportsPresentation {
    let track: TrackPresentation
    var mode: ReportMode = .week
    var weekAnchor: Int64?
    var includeArchived = true
    var selectedProjectID: UUID?
    var scopeTaskID: UUID?
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
    private(set) var weekDayBlocks: [[WeekTimeBlock]] = Array(repeating: [], count: 7)
    private(set) var weekPlotHourRange: ClosedRange<Int> = 9...17
    private(set) var weekTotalSeconds: Int64 = 0
    private(set) var weekDayTotals: [Int64] = Array(repeating: 0, count: 7)
    private(set) var weekProjectLegend: [ProjectLegendItem] = []
    private(set) var timesheetRows: [TimesheetRow] = []
    private(set) var timesheetTotalSeconds: Int64 = 0
    private(set) var error: String?
    private(set) var calendar = Calendar.current

    init(track: TrackPresentation) { self.track = track }

    var visibleProjects: [Project] {
        guard let snapshot = track.workspace.snapshot else { return [] }
        let tasksByID = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        var projectsWithEntries = Set<UUID>()
        for entry in snapshot.entries {
            if let projectID = tasksByID[entry.taskID]?.projectID {
                projectsWithEntries.insert(projectID)
            }
        }
        return snapshot.projects
            .filter { project in
                !project.isArchived
                    || includeArchived
                    || projectsWithEntries.contains(project.id)
                    || selectedProjectID == project.id
            }
            .sorted {
                $0.name == $1.name
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    var availableTaskOptions: [TaskFilterOption] {
        guard let snapshot = track.workspace.snapshot else { return [] }
        let projects: [Project]
        if let selectedProjectID,
            let selected = snapshot.projects.first(where: { $0.id == selectedProjectID }) {
            projects = [selected]
        } else {
            projects = visibleProjects
        }
        let showProjectPrefix = projects.count > 1
        var options: [TaskFilterOption] = []
        for proj in projects {
            for row in track.allRows(projectID: proj.id) {
                let relative = taskPathWithinProject(row.id, projectID: proj.id)
                let title = showProjectPrefix ? "\(proj.name) / \(relative)" : relative
                options.append(TaskFilterOption(id: row.id, projectID: proj.id, title: title))
            }
        }
        return options
    }

    func taskPathWithinProject(_ taskID: UUID, projectID: UUID? = nil) -> String {
        guard let snapshot = track.workspace.snapshot,
            let task = snapshot.tasks.first(where: { $0.id == taskID })
        else { return "Unknown task" }
        let targetProjectID = projectID ?? task.projectID
        let tasksByID = Dictionary(
            uniqueKeysWithValues: snapshot.tasks
                .filter { $0.projectID == targetProjectID }
                .map { ($0.id, $0) }
        )
        var names = [task.name]
        var currentParent = task.parentTaskID
        var visited: Set<UUID> = [task.id]
        while let parentID = currentParent, visited.insert(parentID).inserted,
            let parent = tasksByID[parentID] {
            names.append(parent.name)
            currentParent = parent.parentTaskID
        }
        return names.reversed().joined(separator: " / ")
    }

    func selectProjectFilter(_ projectID: UUID?) {
        selectedProjectID = projectID
        if let projectID, let scopeTaskID,
            let snapshot = track.workspace.snapshot,
            !snapshot.tasks.contains(where: { $0.id == scopeTaskID && $0.projectID == projectID }) {
            self.scopeTaskID = nil
        }
    }

    func selectTaskFilter(_ taskID: UUID?) {
        guard let taskID else {
            clearTaskFilter()
            return
        }
        guard let snapshot = track.workspace.snapshot,
            let task = snapshot.tasks.first(where: { $0.id == taskID })
        else { return }
        if let selectedProjectID, task.projectID != selectedProjectID {
            return
        }
        scopeTaskID = taskID
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
            firstWeekday: firstWeekday, includeArchived: true)
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
        weekDayBlocks = Array(repeating: [], count: 7)
        weekPlotHourRange = 9...17
        weekTotalSeconds = 0
        weekDayTotals = Array(repeating: 0, count: 7)
        weekProjectLegend = []
        timesheetRows = []
        timesheetTotalSeconds = 0
    }

    func refresh(now: Int64, calendar: Calendar) {
        self.calendar = calendar
        error = nil
        guard track.workspace.availability == .ready || track.workspace.availability == .reviewRequired,
            let snapshot = track.workspace.snapshot
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
        if let scopeTaskID,
            !snapshot.tasks.contains(where: {
                $0.id == scopeTaskID && (selectedProjectID == nil || $0.projectID == selectedProjectID)
            }) {
            self.scopeTaskID = nil
        }
        do {
            try refreshWeekly(now: now, calendar: self.calendar, firstWeekday: weekday, snapshot: snapshot)
            refreshTimesheets(snapshot: snapshot)
            if mode == .project {
                if let value = try projectReport(calendar: self.calendar, firstWeekday: weekday) {
                    try applyProjectReport(value)
                } else {
                    clearProjectResults()
                }
            }
        } catch {
            clearResults()
            self.error = "Report unavailable: \(error)"
        }
    }

    private func refreshWeekly(
        now: Int64,
        calendar: Calendar,
        firstWeekday: Int,
        snapshot: LibrarySnapshot
    ) throws {
        let value = try weeklyReport(now: now, calendar: calendar, firstWeekday: firstWeekday)
        let amounts = try ReportProjection.amounts(
            totals: value.projectTotals,
            projects: value.projects
        )
        week = value
        weeklyAmounts = amounts
        buildWeekTimeline(week: value, snapshot: snapshot, calendar: calendar)
    }

    func blockVisualStyle(
        projectID: UUID,
        taskID: UUID,
        orderedProjects: [Project]? = nil
    ) -> BlockVisualStyle {
        let projects = orderedProjects ?? visibleProjects
        let projectIndex = projects.firstIndex(where: { $0.id == projectID }) ?? 0
        let space = ProjectColorSpace.forProjectIndex(projectIndex)
        let projectTaskRows = track.allRows(projectID: projectID)
        let taskCount = max(1, projectTaskRows.count)
        let taskIndex = projectTaskRows.firstIndex(where: { $0.id == taskID }) ?? 0
        let fill = space.color(taskIndex: taskIndex, taskCount: taskCount)
        let accent = space.color(taskIndex: 0, taskCount: max(2, taskCount))
        return BlockVisualStyle(
            projectFamilyIndex: space.familyIndex,
            taskIndex: taskIndex,
            taskCount: taskCount,
            hue: fill.hue,
            saturation: fill.saturation,
            brightness: fill.brightness,
            accentHue: accent.hue,
            accentSaturation: min(1.0, max(fill.saturation, accent.saturation)),
            accentBrightness: max(0.28, fill.brightness * 0.72),
            accentStyle: space.accentStyle
        )
    }

    private func buildWeekTimeline(
        week: WeeklyReport,
        snapshot: LibrarySnapshot,
        calendar: Calendar
    ) {
        let liveEnd = try? track.workspace.trackLiveEnd()
        let projectsByID = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0) })
        let tasksByID = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        let orderedProjects = visibleProjects
        let allowedProjectIDs = Set(orderedProjects.map(\.id))

        var dayBlocks: [[WeekTimeBlock]] = Array(repeating: [], count: week.days.count)
        var dayTotals: [Int64] = Array(repeating: 0, count: week.days.count)
        var totalSeconds: Int64 = 0
        var earliestMinute = 9.0 * 60.0
        var latestMinute = 17.0 * 60.0
        var activeProjectIDsInWeek = Set<UUID>()

        for (dayIndex, day) in week.days.enumerated() {
            guard let dayBounds = day.bounds else { continue }
            var blocksForDay: [WeekTimeBlock] = []
            for entry in snapshot.entries {
                guard let task = tasksByID[entry.taskID],
                    let project = projectsByID[task.projectID],
                    allowedProjectIDs.contains(project.id)
                else { continue }
                if let selectedProjectID, project.id != selectedProjectID {
                    continue
                }
                guard let entryEnd = resolvedEnd(for: entry, snapshot: snapshot, liveEnd: liveEnd),
                    entryEnd > entry.startAt
                else { continue }
                let clippedStart = max(entry.startAt, dayBounds.start)
                let clippedEnd = min(entryEnd, dayBounds.end)
                guard clippedEnd > clippedStart else { continue }

                let duration = clippedEnd - clippedStart
                let startMinute = minuteOfDay(
                    timestamp: clippedStart,
                    dayBounds: dayBounds,
                    isEnd: false,
                    calendar: calendar
                )
                let endMinute = max(
                    startMinute,
                    minuteOfDay(
                        timestamp: clippedEnd,
                        dayBounds: dayBounds,
                        isEnd: true,
                        calendar: calendar
                    )
                )

                earliestMinute = min(earliestMinute, startMinute)
                latestMinute = max(latestMinute, endMinute)
                activeProjectIDsInWeek.insert(project.id)

                let style = blockVisualStyle(
                    projectID: project.id,
                    taskID: task.id,
                    orderedProjects: orderedProjects
                )
                let block = WeekTimeBlock(
                    id: "\(entry.id.uuidString)-\(dayIndex)",
                    entryID: entry.id,
                    dayIndex: dayIndex,
                    projectID: project.id,
                    taskID: task.id,
                    projectName: project.name,
                    taskName: taskPathWithinProject(task.id, projectID: project.id),
                    startAt: clippedStart,
                    endAt: clippedEnd,
                    durationSeconds: duration,
                    startMinuteOfDay: startMinute,
                    endMinuteOfDay: endMinute,
                    style: style,
                    isEditable: entry.endAt != nil
                )
                blocksForDay.append(block)
                dayTotals[dayIndex] += duration
                totalSeconds += duration
            }
            blocksForDay.sort {
                if $0.startAt != $1.startAt { return $0.startAt < $1.startAt }
                if $0.endAt != $1.endAt { return $0.endAt < $1.endAt }
                return $0.id < $1.id
            }
            dayBlocks[dayIndex] = blocksForDay
        }

        let startHour = max(0, min(9, Int(floor(earliestMinute / 60.0))))
        let endHour = min(24, max(17, Int(ceil(latestMinute / 60.0))))
        weekDayBlocks = dayBlocks
        weekDayTotals = dayTotals
        weekTotalSeconds = totalSeconds
        weekPlotHourRange = startHour...max(startHour + 1, endHour)

        let legendProjects = orderedProjects.filter { project in
            if let selectedProjectID {
                return project.id == selectedProjectID
            }
            return activeProjectIDsInWeek.contains(project.id) || !project.isArchived
        }
        weekProjectLegend = legendProjects.map { project in
            let idx = orderedProjects.firstIndex(where: { $0.id == project.id }) ?? 0
            let space = ProjectColorSpace.forProjectIndex(idx)
            let mid = space.color(taskIndex: 0, taskCount: 1)
            return ProjectLegendItem(
                id: project.id,
                name: project.name,
                familyIndex: space.familyIndex,
                swatchHue: mid.hue,
                swatchSaturation: mid.saturation,
                swatchBrightness: mid.brightness,
                accentStyle: space.accentStyle
            )
        }
    }

    private func minuteOfDay(
        timestamp: Int64,
        dayBounds: ReportBounds,
        isEnd: Bool,
        calendar: Calendar
    ) -> Double {
        if isEnd && timestamp >= dayBounds.end {
            return 24.0 * 60.0
        }
        if !isEnd && timestamp <= dayBounds.start {
            return 0.0
        }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hours = Double(components.hour ?? 0)
        let minutes = Double(components.minute ?? 0)
        let seconds = Double(components.second ?? 0)
        return min(24.0 * 60.0, max(0.0, hours * 60.0 + minutes + seconds / 60.0))
    }

    private func refreshTimesheets(snapshot: LibrarySnapshot) {
        let liveEnd = try? track.workspace.trackLiveEnd()
        let projectsByID = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0) })
        let tasksByID = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        let allowedProjectIDs = Set(visibleProjects.map(\.id))
        let scopedTaskIDs = descendantTaskIDs(rootTaskID: scopeTaskID, tasks: snapshot.tasks)

        var rows: [TimesheetRow] = []
        var total: Int64 = 0

        for entry in snapshot.entries {
            guard let task = tasksByID[entry.taskID],
                let project = projectsByID[task.projectID],
                allowedProjectIDs.contains(project.id)
            else { continue }
            if let selectedProjectID, project.id != selectedProjectID {
                continue
            }
            if let scopedTaskIDs, !scopedTaskIDs.contains(task.id) {
                continue
            }
            guard let endAt = resolvedEnd(for: entry, snapshot: snapshot, liveEnd: liveEnd),
                endAt >= entry.startAt
            else { continue }
            let duration = max(0, endAt - entry.startAt)
            total += duration
            rows.append(
                TimesheetRow(
                    id: entry.id,
                    entry: entry,
                    startAt: entry.startAt,
                    endAt: endAt,
                    durationSeconds: duration,
                    projectID: project.id,
                    projectName: project.name,
                    taskID: task.id,
                    taskName: taskPathWithinProject(task.id, projectID: project.id),
                    isEditable: entry.endAt != nil
                )
            )
        }

        rows.sort {
            if $0.startAt != $1.startAt { return $0.startAt < $1.startAt }
            if $0.endAt != $1.endAt { return $0.endAt < $1.endAt }
            return $0.id.uuidString < $1.id.uuidString
        }

        timesheetRows = rows
        timesheetTotalSeconds = total
    }

    private func descendantTaskIDs(rootTaskID: UUID?, tasks: [TaskRecord]) -> Set<UUID>? {
        guard let rootTaskID else { return nil }
        let childrenByParent = Dictionary(
            grouping: tasks.compactMap { task in
                task.parentTaskID.map { (parent: $0, child: task.id) }
            },
            by: \.parent
        )
        var included: Set<UUID> = [rootTaskID]
        var queue: [UUID] = [rootTaskID]
        var index = 0
        while index < queue.count {
            let current = queue[index]
            for child in childrenByParent[current, default: []] where included.insert(child.child).inserted {
                queue.append(child.child)
            }
            index += 1
        }
        return included
    }

    private func resolvedEnd(
        for entry: TimeEntry,
        snapshot: LibrarySnapshot,
        liveEnd: Int64?
    ) -> Int64? {
        if let closed = entry.endAt {
            return closed
        }
        guard let active = snapshot.activeTimer, active.entryID == entry.id else {
            return nil
        }
        if let liveEnd, liveEnd >= active.checkpointAt {
            return liveEnd
        }
        return active.checkpointAt
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
                project: value.project
            )
        }
        for rows in value.entriesByLeaf.values {
            for row in rows {
                entryAmounts[row.id] = try ReportProjection.amount(
                    seconds: row.seconds,
                    project: value.project
                )
            }
        }
        projectAmount = try ReportProjection.amount(
            seconds: value.total.totalSeconds,
            project: value.project
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

    func editTimesheetRow(_ row: TimesheetRow) {
        guard row.isEditable else { return }
        selectedEntryID = row.id
        track.editTime(entryID: row.id)
    }

    func editWeekBlock(_ block: WeekTimeBlock) {
        guard block.isEditable else { return }
        selectedEntryID = block.entryID
        track.editTime(entryID: block.entryID)
    }

    func deleteWeekBlock(_ block: WeekTimeBlock) {
        guard block.isEditable else { return }
        selectedEntryID = block.entryID
        track.deleteTime(entryID: block.entryID)
    }

    func restoreProject(_ id: UUID) { track.editProject(id) }

    func openLabel(entryID: UUID?) -> String {
        if case .running(let id) = track.workspace.timerStatus, entryID == id {
            return "Provisional, live when authorized; otherwise checkpoint only"
        }
        return "Provisional, saved checkpoint only"
    }
}
