import LibraryStore
import SwiftUI

@MainActor struct WeeklyReportView: View {
    let reports: ReportsPresentation
    let now: Int64
    let locale: Locale
    @State private var hoveredBlock: WeekTimeBlock?
    @State private var navigationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            filterAndLegendHeader
            if let navigationError {
                Text(navigationError).foregroundStyle(.red)
            }
            if let week = reports.week {
                weekNavigationBar(week: week)
                weekCalendarTimeline(week: week)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var filterAndLegendHeader: some View {
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

            if !reports.weekProjectLegend.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(reports.weekProjectLegend) { item in
                            HStack(spacing: 5) {
                                Text(item.markerSymbol)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(item.swatchColor)
                                Text(item.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(item.swatchColor.opacity(0.15))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(item.swatchColor.opacity(0.6), lineWidth: 1)
                            )
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func weekNavigationBar(week: WeeklyReport) -> some View {
        HStack(spacing: 12) {
            Button("Previous") { move(-1) }
            Button("This Week") { reports.showThisWeek() }
            Button("Next") { move(1) }
            Spacer()
            if let first = week.days.first?.date, let last = week.days.last?.date {
                let startLabel = ReportFormatting.day(first, calendar: reports.calendar, locale: locale)
                let endLabel = ReportFormatting.day(last, calendar: reports.calendar, locale: locale)
                Text("\(startLabel) – \(endLabel)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text("Total: \(ReportFormatting.totalTime(seconds: reports.weekTotalSeconds))")
                .font(.headline.monospacedDigit())
        }
    }

    private func weekCalendarTimeline(week: WeeklyReport) -> some View {
        let hourRange = reports.weekPlotHourRange
        let startHour = hourRange.lowerBound
        let endHour = hourRange.upperBound
        let totalMinutes = Double(max(60, (endHour - startHour) * 60))
        let axisWidth: CGFloat = 56
        let headerHeight: CGFloat = 46

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: axisWidth, height: headerHeight)
                ForEach(Array(week.days.enumerated()), id: \.offset) { dayIndex, day in
                    dayColumnHeader(day: day, dayIndex: dayIndex)
                        .frame(maxWidth: .infinity, minHeight: headerHeight)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .bottom) {
                Divider()
            }

            GeometryReader { geometry in
                let plotHeight = max(80, geometry.size.height - 16)
                let topInset: CGFloat = 8
                ZStack(alignment: .topLeading) {
                    hourGridLines(
                        startHour: startHour,
                        endHour: endHour,
                        axisWidth: axisWidth,
                        plotHeight: plotHeight,
                        topInset: topInset
                    )

                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: axisWidth, height: plotHeight)
                        ForEach(0..<week.days.count, id: \.self) { dayIndex in
                            dayTimelineColumn(
                                dayIndex: dayIndex,
                                startHour: startHour,
                                totalMinutes: totalMinutes,
                                plotHeight: plotHeight
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .padding(.top, topInset)
                }
            }
            .frame(minHeight: 160, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    private func dayColumnHeader(day: WeeklyReportDay, dayIndex: Int) -> some View {
        let daySeconds = reports.weekDayTotals.indices.contains(dayIndex)
            ? reports.weekDayTotals[dayIndex]
            : 0
        return VStack(spacing: 2) {
            Text(ReportFormatting.weekdayHeader(day.date, calendar: reports.calendar, locale: locale))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(ReportFormatting.totalTime(seconds: daySeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(daySeconds > 0 ? .primary : .secondary)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) {
            Divider()
        }
    }

    private func hourGridLines(
        startHour: Int,
        endHour: Int,
        axisWidth: CGFloat,
        plotHeight: CGFloat,
        topInset: CGFloat
    ) -> some View {
        let hoursCount = max(1, endHour - startHour)
        return ZStack(alignment: .topLeading) {
            ForEach(startHour...endHour, id: \.self) { hour in
                let fraction = CGFloat(hour - startHour) / CGFloat(hoursCount)
                let yOffset = topInset + fraction * plotHeight
                HStack(spacing: 6) {
                    Text(ReportFormatting.hourMark(hour * 60, calendar: reports.calendar, locale: locale))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: axisWidth - 8, alignment: .trailing)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: 1)
                }
                .offset(y: yOffset - 6)
            }
        }
    }

    private func dayTimelineColumn(
        dayIndex: Int,
        startHour: Int,
        totalMinutes: Double,
        plotHeight: CGFloat
    ) -> some View {
        let blocks = reports.weekDayBlocks.indices.contains(dayIndex)
            ? reports.weekDayBlocks[dayIndex]
            : []
        let plotStartMinute = Double(startHour * 60)

        return GeometryReader { columnGeo in
            let width = max(16, columnGeo.size.width - 6)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 1, height: plotHeight)

                ForEach(blocks) { block in
                    let clampedStart = max(plotStartMinute, block.startMinuteOfDay)
                    let clampedEnd = min(plotStartMinute + totalMinutes, max(clampedStart, block.endMinuteOfDay))
                    let topRatio = (clampedStart - plotStartMinute) / totalMinutes
                    let heightRatio = (clampedEnd - clampedStart) / totalMinutes
                    let topY = CGFloat(topRatio) * plotHeight
                    let rawHeight = CGFloat(heightRatio) * plotHeight
                    let blockHeight = max(6, rawHeight)

                    WeekBlockCardView(
                        block: block,
                        calendar: reports.calendar,
                        locale: locale,
                        height: blockHeight,
                        isHovered: hoveredBlock?.id == block.id,
                        isBusy: reports.track.workspace.isBusy,
                        onEdit: {
                            hoveredBlock = nil
                            reports.editWeekBlock(block)
                        },
                        onDelete: {
                            hoveredBlock = nil
                            reports.deleteWeekBlock(block)
                        }
                    )
                    .frame(width: width, height: blockHeight, alignment: .topLeading)
                    .offset(x: 3, y: min(plotHeight - blockHeight, max(0, topY)))
                    .onHover { hovering in
                        if hovering {
                            hoveredBlock = block
                        } else if hoveredBlock?.id == block.id {
                            hoveredBlock = nil
                        }
                    }
                }
            }
        }
        .frame(height: plotHeight)
    }

    private func move(_ offset: Int) {
        do {
            try reports.moveWeek(offset, now: now, calendar: reports.calendar)
            navigationError = nil
        } catch {
            navigationError = "Cannot change week: \(error)"
        }
    }
}

private struct WeekBlockCardView: View {
    let block: WeekTimeBlock
    let calendar: Calendar
    let locale: Locale
    let height: CGFloat
    let isHovered: Bool
    let isBusy: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var durationText: String {
        ReportFormatting.totalTime(seconds: block.durationSeconds)
    }

    private var timeRangeText: String {
        let start = ReportFormatting.timeOfDay(block.startAt, calendar: calendar, locale: locale)
        let end = ReportFormatting.timeOfDay(block.endAt, calendar: calendar, locale: locale)
        return "\(start) – \(end)"
    }

    private var tooltipSummary: String {
        "\(block.projectName)\n\(block.taskName)\n\(timeRangeText)\nDuration: \(durationText)"
    }

    var body: some View {
        let useDarkText = block.style.brightness > 0.72
        let textColor: Color = useDarkText ? .black.opacity(0.88) : .white

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(block.style.fillColor)
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(block.style.accentColor.opacity(0.9), lineWidth: isHovered ? 1.5 : 1)

            HStack(spacing: 4) {
                ProjectAccentStrip(style: block.style.accentStyle, color: block.style.accentColor)
                    .frame(width: 5)

                if height >= 18 {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            Text(block.style.markerSymbol)
                                .font(.caption2.weight(.bold))
                            Text(block.taskName)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                        }
                        if height >= 34 {
                            Text(durationText)
                                .font(.caption2.monospacedDigit())
                                .opacity(0.9)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(textColor)
                    .padding(.vertical, 2)
                    .padding(.trailing, 4)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .contextMenu {
            Button("Edit…", action: onEdit)
                .disabled(!block.isEditable || isBusy)
            Button("Delete…", role: .destructive, action: onDelete)
                .disabled(!block.isEditable || isBusy)
        }
        .help(tooltipSummary)
        .popover(isPresented: Binding(get: { isHovered }, set: { _ in }), arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(block.style.markerSymbol)
                        .foregroundStyle(block.style.accentColor)
                    Text(block.projectName)
                        .font(.subheadline.weight(.semibold))
                }
                Text(block.taskName)
                    .font(.callout)
                Text(timeRangeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("Duration: \(durationText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(block.projectName), \(block.taskName)")
        .accessibilityValue("\(timeRangeText), \(durationText)")
    }
}

private struct ProjectAccentStrip: View {
    let style: ProjectAccentStyle
    let color: Color

    var body: some View {
        GeometryReader { geo in
            switch style {
            case .solid:
                Rectangle()
                    .fill(color)
            case .dashed:
                Path { path in
                    path.move(to: CGPoint(x: geo.size.width / 2, y: 0))
                    path.addLine(to: CGPoint(x: geo.size.width / 2, y: geo.size.height))
                }
                .stroke(color, style: StrokeStyle(lineWidth: geo.size.width, dash: [4, 2]))
            case .doubleBar:
                HStack(spacing: 1) {
                    Rectangle().fill(color).frame(width: 1.5)
                    Rectangle().fill(color).frame(width: 1.5)
                }
            case .dotted:
                Path { path in
                    path.move(to: CGPoint(x: geo.size.width / 2, y: 0))
                    path.addLine(to: CGPoint(x: geo.size.width / 2, y: geo.size.height))
                }
                .stroke(color, style: StrokeStyle(lineWidth: geo.size.width, dash: [2, 2]))
            }
        }
    }
}
