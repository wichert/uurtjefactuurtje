import SwiftUI
import Charts
import LibraryStore

private struct WeekSegment: Identifiable {
    let day: Int
    let project: Project
    let seconds: Int64
    let lowerHours: Double
    let upperHours: Double
    var id: String { "\(day):\(project.id.uuidString)" }
    var series: String { "\(project.name) (\(project.id.uuidString))" }
}

@MainActor struct WeeklyReportView: View {
    let reports: ReportsPresentation
    let now: Int64
    let locale: Locale
    @State private var hoveredSegment: WeekSegment?
    @State private var navigationError: String?

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Previous week") { move(-1) }
                Button("This week") { reports.showThisWeek() }
                Button("Next week") { move(1) }
                Picker("Open project", selection: Binding<UUID?>(get: { nil }, set: { id in
                    if let id { reports.openProject(id) }
                })) {
                    Text("Choose project").tag(UUID?.none)
                    ForEach(reports.visibleProjects) { project in
                        Text(project.name + (project.isArchived ? " (archived)" : "")).tag(Optional(project.id))
                    }
                }
            }
            if let navigationError { Text(navigationError).foregroundStyle(.red) }
            if let week = reports.week {
                Text("Time zone: \(week.timeZoneIdentifier)")
                Text("Total: \(ReportFormatting.duration(seconds: week.total.totalSeconds))")
                ForEach(Array(reports.weeklyAmounts.enumerated()), id: \.offset) { _, amount in
                    Text("Current-rate total: \(ReportFormatting.amount(amount, locale: locale))")
                }
                if week.hasOpenEntry {
                    Text(reports.openLabel(entryID: reports.track.workspace.snapshot?.activeTimer?.entryID))
                }
                let segments = week.days.enumerated().flatMap { index, day -> [WeekSegment] in
                    var height = 0.0
                    return week.projects.map { project in
                        let seconds = day.projects[project.id]?.totalSeconds ?? 0
                        let lower = height
                        height += Double(seconds) / 3600
                        return WeekSegment(
                            day: index, project: project, seconds: seconds,
                            lowerHours: lower, upperHours: height,
                        )
                    }
                }
                Chart(segments) { segment in
                    BarMark(x: .value("Day", Double(segment.day)),
                            yStart: .value("From hours", segment.lowerHours),
                            yEnd: .value("To hours", segment.upperHours))
                        .foregroundStyle(by: .value("Project", segment.series))
                        .accessibilityLabel(
                            "\(segment.series), " + ReportFormatting.day(
                                week.days[segment.day].date, calendar: reports.calendar,
                            )
                        )
                        .accessibilityValue(ReportFormatting.duration(seconds: segment.seconds))
                }
                .chartXScale(domain: -0.5...6.5)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        if let plot = proxy.plotFrame {
                            let frame = geometry[plot]
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case let .active(point): hoveredSegment = hitActive(point, frame, proxy, segments)
                                    case .ended: hoveredSegment = nil
                                    }
                                }
                                .gesture(SpatialTapGesture().onEnded { event in
                                    if let segment = hit(
                                        event.location, frame: frame, proxy: proxy, segments: segments
                                    ),
                                       week.days.indices.contains(segment.day) {
                                        reports.openDay(projectID: segment.project.id, day: week.days[segment.day])
                                    }
                                })
                        }
                    }
                }
                .frame(minHeight: 180)
                if let segment = hoveredSegment, week.days.indices.contains(segment.day) {
                    Text(segmentTooltip(segment, week: week))
                }
                Text("Exact project/day values; select any ordinary cell to open that day.")
                ScrollView(.horizontal) {
                    Grid(alignment: .leading) {
                        GridRow {
                            Text("Project")
                            ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                                Text(ReportFormatting.day(day.date, calendar: reports.calendar))
                            }
                        }
                        ForEach(week.projects) { project in
                            GridRow {
                                Text(project.name + (project.isArchived ? " (archived)" : ""))
                                ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                                    cell(project: project, day: day)
                                }
                            }
                        }
                    }
                }
                Text("""
                Amounts use current project rates, grouped by currency; no conversion. \
                Chart hours are geometry only.
                """)
                    .font(.caption)
            }
        }
    }

    private func segmentTooltip(_ segment: WeekSegment, week: WeeklyReport) -> String {
        let day = ReportFormatting.day(
            week.days[segment.day].date, calendar: reports.calendar
        )
        return "\(segment.project.name) — \(day): "
            + ReportFormatting.duration(seconds: segment.seconds)
    }

    private func hitActive(
        _ point: CGPoint,
        _ frame: CGRect,
        _ proxy: ChartProxy,
        _ segments: [WeekSegment],
    ) -> WeekSegment? {
        hit(point, frame: frame, proxy: proxy, segments: segments)
    }

    @ViewBuilder private func cell(project: Project, day: WeeklyReportDay) -> some View {
        let duration = ReportFormatting.duration(seconds: day.projects[project.id]?.totalSeconds ?? 0)
        let date = ReportFormatting.day(day.date, calendar: reports.calendar)
        if day.bounds != nil {
            Button(duration) { reports.openDay(projectID: project.id, day: day) }
                .accessibilityLabel("\(project.name), \(date), \(duration)")
                .help("\(project.name) — \(date): \(duration)")
        } else {
            Text("Skipped day — 0 seconds").accessibilityLabel("\(date), skipped day, zero seconds")
        }
    }

    private func hit(_ point: CGPoint, frame: CGRect, proxy: ChartProxy, segments: [WeekSegment]) -> WeekSegment? {
        guard frame.contains(point),
              let horizontal: Double = proxy.value(atX: point.x - frame.minX),
              let vertical: Double = proxy.value(atY: point.y - frame.minY) else { return nil }
        let day = Int(horizontal.rounded())
        guard abs(horizontal - Double(day)) <= 0.5 else { return nil }
        return segments.first {
            $0.day == day && $0.lowerHours <= vertical && vertical < $0.upperHours
        }
    }

    private func move(_ offset: Int) {
        do {
            try reports.moveWeek(offset, now: now, calendar: reports.calendar)
            navigationError = nil
        } catch { navigationError = "Cannot change week: \(error)" }
    }
}
