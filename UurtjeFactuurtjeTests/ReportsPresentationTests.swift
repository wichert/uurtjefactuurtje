import Foundation
import Testing
import LibraryStore
@testable import UurtjeFactuurtje

@MainActor private func withReports(
    _ body: (WorkspaceModel, TrackPresentation, ReportsPresentation) async throws -> Void
) async throws {
    try await withTrack { track, _ in
        try await body(track.workspace, track, ReportsPresentation(track: track))
    }
}

@MainActor struct ReportsPresentationTests {
    private func addProject(_ workspace: WorkspaceModel, _ name: String, currency: String = "EUR") async throws -> UUID {
        let id = UUID(), snapshot = try #require(workspace.snapshot)
        _ = try await workspace.submit(.createProject(id: id, name: name, rate: 60, currency: currency),
                                       expectedRevision: snapshot.revision)
        return id
    }

    private func addTask(_ workspace: WorkspaceModel, projectID: UUID, name: String) async throws -> UUID {
        let id = UUID(), snapshot = try #require(workspace.snapshot)
        _ = try await workspace.submit(.createTask(id: id, projectID: projectID, parentID: nil, name: name),
                                       expectedRevision: snapshot.revision)
        return id
    }

    private func calendar(_ zone: String) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }

    @Test func testWeekDrilldownBackAndIndependentState() async throws {
        try await withReports { workspace, _, reports in
            let project = try await addProject(workspace, "Alpha")
            let task = try await addTask(workspace, projectID: project, name: "Task")
            let now: Int64 = 1_710_000_000
            let cal = calendar("Europe/Amsterdam")
            reports.weekAnchor = now
            reports.includeArchived = true
            reports.refresh(now: now, calendar: cal)
            let week = try #require(reports.week)
            #expect(week.days.count == 7)
            #expect(week.days.allSatisfy { ($0.projects[project]?.totalSeconds ?? 0) == 0 })
            let day = week.days[0]
            reports.openDay(projectID: project, day: day)
            #expect(reports.selectedProjectID == project)
            let dayStart = try #require(day.bounds?.start)
            #expect(reports.period == .day(containing: dayStart))
            reports.expandedTaskIDs.insert(task)
            reports.selectedLeafID = task
            reports.period = .thisWeek
            reports.refresh(now: now, calendar: cal)
            #expect(reports.selectedLeafID == task)
            #expect(reports.expandedTaskIDs.contains(task))
            reports.backToWeek()
            #expect(reports.weekAnchor == now)
            #expect(reports.includeArchived)
            #expect(reports.mode == .week)
        }
    }

    @Test func testCalendarPreferenceAndZoneRefreshWithoutWrites() async throws {
        try await withReports { workspace, _, reports in
            _ = try await addProject(workspace, "Alpha")
            let revision = try #require(workspace.snapshot).revision
            let now: Int64 = 1_711_849_200
            try await workspace.setFirstWeekday(2)
            reports.refresh(now: now, calendar: calendar("Europe/Amsterdam"))
            let monday = try #require(reports.week)
            #expect(monday.days.count == 7)
            #expect(monday.timeZoneIdentifier == "Europe/Amsterdam")
            try await workspace.setFirstWeekday(1)
            reports.refresh(now: now, calendar: calendar("Europe/Amsterdam"))
            let sunday = try #require(reports.week)
            #expect(monday.bounds.start != sunday.bounds.start)
            reports.refresh(now: now, calendar: calendar("Pacific/Apia"))
            #expect(reports.week?.timeZoneIdentifier == "Pacific/Apia")
            #expect(workspace.snapshot?.revision == revision)
        }
    }

    @Test func testArchiveSwitchAndSharedRoutes() async throws {
        try await withReports { workspace, track, reports in
            let first = try await addProject(workspace, "Alpha")
            let second = try await addProject(workspace, "Beta")
            let task = try await addTask(workspace, projectID: first, name: "Leaf")
            reports.openProject(first)
            reports.period = .thisMonth
            reports.expandedTaskIDs.insert(task)
            reports.selectedLeafID = task
            reports.openProject(second)
            #expect(reports.period == .allTime)
            #expect(reports.expandedTaskIDs.isEmpty)
            #expect(reports.selectedLeafID == nil)
            _ = try await workspace.submit(.setArchived(id: second, archived: true), expectedRevision: try #require(workspace.snapshot).revision)
            reports.refresh(now: 1_710_000_000, calendar: calendar("UTC"))
            #expect(reports.selectedProjectID == nil)
            reports.openProject(first)
            reports.addTime(taskID: task)
            let sheet = try #require(track.sheet?.id)
            reports.reviewTime()
            #expect(track.sheet?.id == sheet, "Review must not replace an existing draft")
            reports.restoreProject(first)
            #expect(track.sheet?.id == sheet, "Restore must not replace an existing draft")
        }
    }

    @Test func testExactCurrencyAndDuration() throws {
        let locale = Locale(identifier: "en_US_POSIX")
        let project = Project(id: UUID(), name: "P", hourlyRate: 1, currencyCode: "JPY")
        let yen = try ReportProjection.amount(seconds: 3600, project: project)
        #expect(ReportFormatting.amount(yen, locale: locale) == "JPY 1")
        #expect(ReportFormatting.duration(seconds: 3661) == "1 h 1 min 1 sec (3661 seconds)")
        let kwd = Project(id: UUID(), name: "P", hourlyRate: 1, currencyCode: "KWD")
        #expect(ReportFormatting.amount(try ReportProjection.amount(seconds: 3600, project: kwd), locale: locale) == "KWD 1.000")
        let huge = Project(id: UUID(), name: "P", hourlyRate: Decimal(string: "1000000000000000000000000000000000000")!, currencyCode: "EUR")
        let amount = try ReportProjection.amount(seconds: Int64.max, project: huge)
        #expect(ReportFormatting.amount(amount, locale: locale) == "EUR 2562047788015215501944444444444444444444444444444444.44")
    }

    @Test func testClippedRowKeepsOriginalEntryAndPeriodBudgetSeparation() async throws {
        try await withReports { workspace, track, reports in
            let project = try await addProject(workspace, "Alpha")
            let task = try await addTask(workspace, projectID: project, name: "Leaf")
            let id = UUID()
            let start: Int64 = 1_704_063_000
            let end: Int64 = 1_704_070_200
            let preview = try CorrectionPlanner.preview(.add(id: id, taskID: task, startAt: start, endAt: end), in: #require(workspace.snapshot))
            _ = try await workspace.enqueueCorrection(.apply(preview)).value
            reports.openProject(project)
            reports.period = .day(containing: 1_704_067_200)
            reports.refresh(now: 1_710_000_000, calendar: calendar("UTC"))
            let report = try #require(reports.project)
            let row = try #require(report.entriesByLeaf[task]?.first)
            #expect(row.entry.id == id)
            #expect(row.entry.startAt == start)
            #expect(row.entry.endAt == end)
            #expect(row.seconds < end - start)
            #expect(report.lifetimeUsage[task] == Decimal(end - start))
            #expect(report.taskTotals[task]?.totalSeconds == row.seconds)
            reports.addTime(taskID: task)
            let existingSheet = try #require(track.sheet?.id)
            reports.editEntry(row)
            #expect(track.sheet?.id == existingSheet, "Edit must not replace an existing draft")
            track.cancelSheet()
            reports.editEntry(row)
            #expect(reports.selectedEntryID == id)
            if case .correction(let route) = track.sheet {
                if case .edit(let entryID) = route.mode { #expect(entryID == id) }
                else { Issue.record("Expected edit route") }
            } else { Issue.record("Expected correction sheet") }
        }
    }

    @Test func testSkippedCivilDayCannotDrillDown() async throws {
        try await withReports { workspace, _, reports in
            let project = try await addProject(workspace, "Apia")
            var cal = calendar("Pacific/Apia")
            cal.firstWeekday = 2
            let date = try #require(cal.date(from: DateComponents(year: 2011, month: 12, day: 29, hour: 12)))
            reports.refresh(now: Int64(date.timeIntervalSince1970), calendar: cal)
            let week = try #require(reports.week)
            let skipped = try #require(week.days.first(where: { $0.bounds == nil }))
            reports.openDay(projectID: project, day: skipped)
            #expect(reports.mode == .week)
            #expect(reports.selectedProjectID == nil)
        }
    }

    @Test func testInvalidCustomPeriodClearsProjection() async throws {
        try await withReports { workspace, _, reports in
            let id = try await addProject(workspace, "Alpha")
            reports.openProject(id)
            reports.refresh(now: 1_710_000_000, calendar: calendar("UTC"))
            #expect(reports.project != nil)
            reports.applyCustom(first: DateComponents(year: 2024, month: 2, day: 31),
                                last: DateComponents(year: 2024, month: 3, day: 2))
            reports.refresh(now: 1_710_000_000, calendar: calendar("UTC"))
            #expect(reports.project == nil)
            #expect(reports.error != nil)
        }
    }

    @Test func testDSTWeekAndLiveRefreshDoNotWrite() async throws {
        try await withReports { workspace, _, reports in
            let project = try await addProject(workspace, "Clock")
            let task = try await addTask(workspace, projectID: project, name: "Timer")
            _ = try await workspace.enqueueTimer(.start(taskID: task)).value
            let revision = try #require(workspace.snapshot).revision
            reports.refresh(now: 1_711_849_200, calendar: calendar("Europe/Amsterdam"))
            let week = try #require(reports.week)
            #expect(week.days.count == 7)
            #expect(week.days.compactMap(\.bounds).contains { $0.end - $0.start == 23 * 3600 })
            let label = reports.openLabel(entryID: workspace.snapshot?.activeTimer?.entryID)
            #expect(label.contains("Provisional"))
            reports.refresh(now: 1_711_849_201, calendar: calendar("Europe/Amsterdam"))
            #expect(workspace.snapshot?.revision == revision)
            #expect(reports.openLabel(entryID: UUID()).contains("saved checkpoint"))
        }
    }

    @Test func testDuplicateNamesAndZeroCellDrilldown() async throws {
        try await withReports { workspace, _, reports in
            let first = try await addProject(workspace, "Identical")
            let second = try await addProject(workspace, "Identical")
            reports.refresh(now: 1_710_000_000, calendar: calendar("UTC"))
            let week = try #require(reports.week)
            #expect(Set(week.projects.map(\.id)) == Set([first, second]))
            let day = week.days[0]
            #expect(day.projects[second]?.totalSeconds ?? 0 == 0)
            reports.openDay(projectID: second, day: day)
            #expect(reports.selectedProjectID == second)
            let dayStart = try #require(day.bounds?.start)
            #expect(reports.period == .day(containing: dayStart))
        }
    }

    @Test func testUnavailableClearsResults() async throws {
        try await withReports { workspace, _, reports in
            _ = try await addProject(workspace, "Alpha")
            reports.refresh(now: 1_710_000_000, calendar: calendar("UTC"))
            #expect(reports.week != nil)
            try await workspace.close()
            reports.refresh(now: 1_710_000_000, calendar: calendar("UTC"))
            #expect(reports.week == nil)
            #expect(reports.error != nil)
        }
    }
}
