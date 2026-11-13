import LibraryStore
import SwiftUI

private struct ReportRefreshKey: Equatable {
    let snapshot: LibrarySnapshot?
    let availability: WorkspaceAvailability
    let timerStatus: TimerStatus
    let firstWeekday: Int?
    let mode: ReportMode
    let anchor: Int64?
    let includeArchived: Bool
    let projectID: UUID?
    let scopeTaskID: UUID?
    let period: ReportPeriod
    let calendar: Calendar
    let second: Int64
}

@MainActor struct ReportsView: View {
    let reports: ReportsPresentation
    @Environment(\.calendar) private var environmentCalendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = Int64(timeline.date.timeIntervalSince1970.rounded(.down))
            let calendar = capturedCalendar
            let workspace = reports.track.workspace
            let key = ReportRefreshKey(
                snapshot: workspace.snapshot, availability: workspace.availability,
                timerStatus: workspace.timerStatus, firstWeekday: workspace.firstWeekday,
                mode: reports.mode, anchor: reports.weekAnchor,
                includeArchived: reports.includeArchived, projectID: reports.selectedProjectID,
                scopeTaskID: reports.scopeTaskID, period: reports.period,
                calendar: calendar, second: now)
            VStack(alignment: .leading) {
                Picker("Report", selection: Binding(get: { reports.mode }, set: { reports.mode = $0 })) {
                    Text("Week").tag(ReportMode.week)
                    Text("Project").tag(ReportMode.project)
                }.pickerStyle(.segmented)
                Toggle(
                    "Include archived projects",
                    isOn: Binding(
                        get: { reports.includeArchived },
                        set: { reports.includeArchived = $0 },
                    )
                )
                if let error = reports.error {
                    Text(error).foregroundStyle(.red).accessibilityLabel("Report error: \(error)")
                }
                if reports.mode == .week {
                    WeeklyReportView(reports: reports, now: now, locale: locale)
                } else {
                    ProjectReportView(reports: reports, locale: locale)
                }
                Button("Review time…") { reports.reviewTime() }
                Text("Pending sleep is excluded until included in a committed review.")
                    .font(.caption)
            }
            .padding()
            .task(id: key) {
                reports.refresh(now: now, calendar: calendar)
            }
        }
    }

    private var capturedCalendar: Calendar {
        var calendar = environmentCalendar
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }
}
