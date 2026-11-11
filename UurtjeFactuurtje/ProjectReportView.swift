import SwiftUI
import LibraryStore

private struct ReportTaskRow: Identifiable {
    let task: TaskRecord
    let depth: Int
    let hasChildren: Bool
    var id: UUID { task.id }
}

@MainActor struct ProjectReportView: View {
    let reports: ReportsPresentation
    let locale: Locale
    @State private var firstDraft = Date()
    @State private var lastDraft = Date()
    @State private var dateError: String?

    private var rows: [ReportTaskRow] {
        guard let report = reports.project else { return [] }
        let children = Dictionary(grouping: report.tasks, by: \.parentTaskID)
        let roots = report.scopeTask.map { [$0] } ?? (children[nil] ?? [])
        var stack: [(TaskRecord, Int)] = roots.reversed().map { ($0, 0) }
        var result: [ReportTaskRow] = []
        while let (task, depth) = stack.popLast() {
            let descendants = children[task.id] ?? []
            result.append(ReportTaskRow(task: task, depth: depth, hasChildren: !descendants.isEmpty))
            if reports.expandedTaskIDs.contains(task.id) {
                stack.append(contentsOf: descendants.reversed().map { ($0, depth + 1) })
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                if reports.returnToWeek != nil { Button("Back to week") { reports.backToWeek() } }
                Picker("Project", selection: Binding<UUID?>(get: { reports.selectedProjectID }, set: { id in
                    if let id { reports.openProject(id) }
                })) {
                    Text("Choose project").tag(UUID?.none)
                    ForEach(reports.visibleProjects) { project in
                        Text(project.name + (project.isArchived ? " (archived)" : "")).tag(Optional(project.id))
                    }
                }
            }
            if let scope = reports.scopeTaskID {
                HStack {
                    Text("Task scope: \(reports.track.path(scope))")
                        .textSelection(.enabled)
                    Button("Clear task filter") { reports.clearTaskFilter() }
                }
            }
            if reports.selectedProjectID != nil {
                HStack {
                    Button("All time") { reports.period = .allTime }
                    Button("This week") { reports.period = .thisWeek }
                    Button("This month") { reports.period = .thisMonth }
                }
                HStack {
                    DatePicker("From", selection: $firstDraft, displayedComponents: .date)
                    DatePicker("Through", selection: $lastDraft, displayedComponents: .date)
                    Button("Apply dates") {
                        let first = reports.calendar.dateComponents([.era, .year, .month, .day], from: firstDraft)
                        let last = reports.calendar.dateComponents([.era, .year, .month, .day], from: lastDraft)
                        if reports.calendar.startOfDay(for: firstDraft) > reports.calendar.startOfDay(for: lastDraft) {
                            dateError = "The first date must not be after the last date."
                        } else {
                            dateError = nil
                            reports.applyCustom(first: first, last: last)
                        }
                    }
                }
                .environment(\.calendar, reports.calendar)
                .environment(\.timeZone, reports.calendar.timeZone)
                if let dateError { Text(dateError).foregroundStyle(.red) }
            }
            if let report = reports.project, let totalAmount = reports.projectAmount {
                Text("\(report.project.name)\(report.project.isArchived ? " (archived)" : "") — \(periodLabel(report))")
                Text("Time zone: \(report.timeZoneIdentifier)")
                let totalTime = ReportFormatting.duration(seconds: report.total.totalSeconds)
                let total = ReportFormatting.amount(totalAmount, locale: locale)
                Text("Period total: \(totalTime); \(total)")
                let rate = NSDecimalNumber(decimal: report.project.hourlyRate).stringValue
                Text("""
                    Current rate: \(rate) \(report.project.currencyCode) per hour. Current rates apply to all history; \
                    rows round independently, without conversion.
                    """)
                    .font(.caption)
                if report.hasOpenEntry {
                    Text(reports.openLabel(entryID: reports.track.workspace.snapshot?.activeTimer?.entryID))
                }
                if report.project.isArchived {
                    Button("Restore project…") { reports.restoreProject(report.project.id) }
                }
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(rows) { row in
                            taskRow(row, report: report)
                        }
                    }
                }
                if let leaf = reports.selectedLeafID {
                    Button("Add time…") { reports.addTime(taskID: leaf) }
                        .disabled(report.project.isArchived)
                    ForEach(report.entriesByLeaf[leaf] ?? []) { row in
                        entryRow(row, report: report)
                    }
                }
            } else if reports.selectedProjectID == nil {
                Text("Choose a project to view its report.")
            }
        }
    }

    @ViewBuilder private func taskRow(_ row: ReportTaskRow, report: ProjectReport) -> some View {
        HStack(alignment: .top) {
            if row.hasChildren {
                Button(reports.expandedTaskIDs.contains(row.id) ? "▾" : "▸") {
                    if !reports.expandedTaskIDs.insert(row.id).inserted { reports.expandedTaskIDs.remove(row.id) }
                }.accessibilityLabel(
                    "\(reports.expandedTaskIDs.contains(row.id) ? "Collapse" : "Expand") \(row.task.name)"
                )
            } else {
                Button(row.task.name) {
                    reports.selectedLeafID = row.id
                    reports.selectedEntryID = nil
                }
            }
            if row.hasChildren { Text(row.task.name) }
            Text("Period: \(ReportFormatting.duration(seconds: report.taskTotals[row.id]?.totalSeconds ?? 0))")
            if let amount = reports.taskAmounts[row.id] { Text(ReportFormatting.amount(amount, locale: locale)) }
            if let budget = row.task.budgetMinutes {
                if let used = report.lifetimeUsage[row.id] {
                    Text(lifetimeUsage(used: used, budget: budget, report: report, row: row))
                } else {
                    Text("Lifetime budget usage unavailable")
                }
            }
        }.padding(.leading, CGFloat(row.depth) * 16)
    }

    @ViewBuilder private func entryRow(_ row: ReportEntryRow, report: ProjectReport) -> some View {
        VStack(alignment: .leading) {
            let entry = row.entry
            Text(savedInterval(entry))
            Text(currentRate(project: report.project))
            if let interval = row.included {
                let included = ReportFormatting.interval(
                    interval.startAt,
                    interval.endAt,
                    calendar: reports.calendar,
                )
                Text("Included interval: \(included)")
            } else {
                Text("Included interval: zero-length open entry")
            }
            Text("Included duration: \(ReportFormatting.duration(seconds: row.seconds))")
            if let amount = reports.entryAmounts[row.id] {
                Text("Current-rate amount: \(ReportFormatting.amount(amount, locale: locale))")
            }
            if row.isProvisional { Text(reports.openLabel(entryID: entry.id)) }
            if entry.endAt != nil {
                Button("Edit saved entry…") {
                    reports.editEntry(row)
                }
            } else {
                Button("Review open time…") { reports.reviewTime() }
            }
        }.padding(.vertical, 4)
    }

    private func lifetimeUsage(
        used: Decimal,
        budget: Int64,
        report: ProjectReport,
        row: ReportTaskRow,
    ) -> String {
        let allocated = ReportFormatting.budgetHours(seconds: used, locale: locale)
        let limit = ReportFormatting.budgetHours(
            seconds: Decimal(budget) * 60,
            locale: locale,
        )
        let balance = ReportFormatting.budgetBalance(used: used, budget: budget, locale: locale)
        let displayBand = report.displayBands[row.id].map { band($0) } ?? "unavailable"
        return "Lifetime usage: \(allocated) / \(limit); \(balance); band: \(displayBand)"
    }

    private func savedInterval(_ entry: TimeEntry) -> String {
        let calendar = reports.calendar
        let start = ReportFormatting.instant(entry.startAt, calendar: calendar)
        let end = entry.endAt.map { ReportFormatting.instant($0, calendar: calendar) } ?? "open"
        return "Saved entry: \(start) – \(end)"
    }

    private func currentRate(project: Project) -> String {
        let rate = NSDecimalNumber(decimal: project.hourlyRate).stringValue
        return "Current rate: \(rate) \(project.currencyCode) per hour"
    }

    private func periodLabel(_ report: ProjectReport) -> String {
        guard let bounds = report.bounds else { return "All time" }
        return "\(ReportFormatting.interval(bounds.start, bounds.end, calendar: reports.calendar)) (end exclusive)"
    }

    private func band(_ threshold: WarningThreshold) -> String {
        switch threshold {
        case .none: "below warning"
        case .eighty: "80% warning"
        case .hundred: "100% warning"
        }
    }
}
