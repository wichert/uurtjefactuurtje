import LibraryStore
import SwiftUI

private struct ReportRefreshKey: Equatable {
    let snapshot: LibrarySnapshot?
    let availability: WorkspaceAvailability
    let timerStatus: TimerStatus
    let firstWeekday: Int?
    let mode: ReportMode
    let anchor: Int64?
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
                projectID: reports.selectedProjectID,
                scopeTaskID: reports.scopeTaskID, period: reports.period,
                calendar: calendar, second: now)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("View", selection: Binding(get: { reports.mode }, set: { reports.mode = $0 })) {
                        Text("Summary").tag(ReportMode.week)
                        Text("Timesheets").tag(ReportMode.project)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260)
                    Spacer()
                }
                if let error = reports.error {
                    Text(error).foregroundStyle(.red).accessibilityLabel("Report error: \(error)")
                }
                if reports.mode == .week {
                    WeeklyReportView(reports: reports, now: now, locale: locale)
                } else {
                    ProjectReportView(reports: reports, locale: locale)
                }
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
