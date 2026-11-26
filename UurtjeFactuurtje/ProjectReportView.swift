import LibraryStore
import SwiftUI

@MainActor struct ProjectReportView: View {
    let reports: ReportsPresentation
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            filterHeader
            if reports.timesheetRows.isEmpty {
                emptyState
            } else {
                timesheetsTable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var filterHeader: some View {
        HStack(spacing: 16) {
            Picker(
                "Project",
                selection: Binding<UUID?>(
                    get: { reports.selectedProjectID },
                    set: { reports.selectProjectFilter($0) }
                )
            ) {
                Text("All Projects").tag(UUID?.none)
                ForEach(reports.visibleProjects) { project in
                    Text(project.name).tag(Optional(project.id))
                }
            }
            .frame(maxWidth: 260)

            Picker(
                "Task",
                selection: Binding<UUID?>(
                    get: { reports.scopeTaskID },
                    set: { reports.selectTaskFilter($0) }
                )
            ) {
                Text("All Tasks").tag(UUID?.none)
                ForEach(reports.availableTaskOptions) { option in
                    Text(option.title).tag(Optional(option.id))
                }
            }
            .frame(maxWidth: 320)

            Spacer()

            Text("Total: \(ReportFormatting.totalTime(seconds: reports.timesheetTotalSeconds))")
                .font(.headline.monospacedDigit())
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No tracked time entries match the current filters.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.vertical, 40)
    }

    private var timesheetsTable: some View {
        Table(reports.timesheetRows) {
            TableColumn("Date") { row in
                Text(ReportFormatting.date(row.startAt, calendar: reports.calendar, locale: locale))
                    .monospacedDigit()
            }
            .width(min: 100, ideal: 120, max: 160)

            TableColumn("Start Time") { row in
                Text(ReportFormatting.timeOfDay(row.startAt, calendar: reports.calendar, locale: locale))
                    .monospacedDigit()
            }
            .width(min: 75, ideal: 88, max: 110)

            TableColumn("End Time") { row in
                Text(ReportFormatting.timeOfDay(row.endAt, calendar: reports.calendar, locale: locale))
                    .monospacedDigit()
            }
            .width(min: 75, ideal: 88, max: 110)

            TableColumn("Project") { row in
                Text(row.projectName)
                    .lineLimit(1)
            }
            .width(min: 110, ideal: 160)

            TableColumn("Task") { row in
                Text(row.taskName)
                    .lineLimit(1)
            }
            .width(min: 150, ideal: 240)

            TableColumn("") { row in
                if row.isEditable {
                    Button("Edit…") {
                        reports.editTimesheetRow(row)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Edit time entry for \(row.projectName), \(row.taskName)")
                }
            }
            .width(min: 52, ideal: 60, max: 72)
        }
    }
}
