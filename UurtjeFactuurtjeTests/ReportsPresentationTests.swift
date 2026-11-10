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

extension ReportsPresentationTests {
    @Test func compactBudgetHoursAreLocalizedAndMarkRounding() {
        let en = Locale(identifier: "en_US_POSIX"), nl = Locale(identifier: "nl_NL")
        #expect(ReportFormatting.budgetHours(seconds: 0, locale: en) == "0 h")
        #expect(ReportFormatting.budgetHours(seconds: 1, locale: en) == "<0.01 h")
        #expect(ReportFormatting.budgetHours(seconds: 18, locale: en) == "≈0.01 h")
        #expect(ReportFormatting.budgetHours(seconds: 36, locale: en) == "0.01 h")
        #expect(ReportFormatting.budgetHours(seconds: 3599, locale: en) == "≈1 h")
        #expect(ReportFormatting.budgetHours(seconds: 3600, locale: en) == "1 h")
        #expect(ReportFormatting.budgetHours(seconds: 3601, locale: en) == "≈1 h")
        #expect(ReportFormatting.budgetHours(seconds: 4500, locale: nl) == "1,25 h")
        #expect(ReportFormatting.budgetHours(seconds: 1, locale: nl) == "<0,01 h")
        #expect(ReportFormatting.duration(seconds: 3661) == "1 h 1 min 1 sec (3661 seconds)")
    }

    @Test func compactBudgetStatesUseExactSecondsNotRoundedHours() {
        let locale = Locale(identifier: "en_US_POSIX")
        #expect(ReportFormatting.budgetBalance(used: 3599, budget: 60, locale: locale) == "<0.01 h remaining")
        #expect(ReportFormatting.budgetBalance(used: 3600, budget: 60, locale: locale) == "Budget reached")
        #expect(ReportFormatting.budgetBalance(used: 3601, budget: 60, locale: locale) == "<0.01 h overrun")
        for (used, band) in [(Decimal(2879), WarningThreshold.none), (2880, .eighty), (3599, .eighty), (3600, .hundred), (3601, .hundred)] {
            #expect(BudgetRules.band(used: used, budget: 60) == band)
        }
        let max = Decimal(Int64.max)
        #expect(ReportFormatting.budgetHours(seconds: max, locale: locale) == "≈2562047788015215.5 h")
        #expect(ReportFormatting.budgetHours(seconds: max * 2, locale: locale) == "≈5124095576030431 h")
        #expect(ReportFormatting.budgetBalance(used: max * 60 + 1, budget: .max, locale: locale) == "<0.01 h overrun")
        #expect(ReportFormatting.budgetBalance(used: max * 60 - 1, budget: .max, locale: locale) == "<0.01 h remaining")
        #expect(ReportFormatting.budgetAllocation(allocated: max * 2, budget: .max, locale: locale)
            == "Allocated ≈307445734561825860.23 h / ≈153722867280912930.12 h; ≈153722867280912930.12 h overallocated")
    }

    @Test func compactAllocationsKeepNearestFrontierAndLargeDecimalTotals() throws {
        let projectID = UUID(), root = UUID(), bridge = UUID(), child = UUID(), grandchild = UUID(), sibling = UUID()
        func snapshot(_ limit: Int64, _ first: Int64, _ second: Int64) -> LibrarySnapshot {
            LibrarySnapshot(schemaVersion: 2, revision: 0,
                projects: [Project(id: projectID, name: "Client", hourlyRate: 60, currencyCode: "EUR")],
                tasks: [
                    TaskRecord(id: root, projectID: projectID, name: "Root", budgetMinutes: limit),
                    TaskRecord(id: bridge, projectID: projectID, parentTaskID: root, name: "Bridge"),
                    TaskRecord(id: child, projectID: projectID, parentTaskID: bridge, name: "Child", budgetMinutes: first),
                    TaskRecord(id: grandchild, projectID: projectID, parentTaskID: child, name: "Grandchild", budgetMinutes: 1),
                    TaskRecord(id: sibling, projectID: projectID, parentTaskID: root, name: "Sibling", budgetMinutes: second)
                ], entries: [], activeTimer: nil, pendingSleepIntervals: [])
        }
        let locale = Locale(identifier: "en_US_POSIX")
        let exact = try BudgetRules.allocations(in: snapshot(60, 30, 30))
        let allocation = try #require(exact.first { $0.taskID == root })
        #expect(allocation.allocatedMinutes == 60, "Do not double-count the grandchild through its budgeted parent")
        #expect(ReportFormatting.budgetAllocation(allocated: allocation.allocatedMinutes, budget: allocation.limitMinutes, locale: locale)
            == "Allocated 1 h / 1 h; 0 h unallocated")
        let nearly = try BudgetRules.allocations(in: snapshot(60, 30, 29))
        let near = try #require(nearly.first { $0.taskID == root })
        #expect(ReportFormatting.budgetAllocation(allocated: near.allocatedMinutes, budget: near.limitMinutes, locale: locale)
            == "Allocated ≈0.98 h / 1 h; ≈0.02 h unallocated")
        let excessive = snapshot(.max, .max, .max)
        let huge = try #require(try BudgetRules.allocations(in: excessive).first { $0.taskID == root })
        #expect(huge.allocatedMinutes == Decimal(Int64.max) * 2)
        #expect(SnapshotValidator.violations(in: excessive).contains { $0.code == .allocation && $0.recordID == root })
        #expect(ReportFormatting.budgetAllocation(allocated: huge.allocatedMinutes, budget: huge.limitMinutes, locale: locale).hasSuffix("overallocated"))
    }

    @Test func budgetDisplayDoesNotChangeMixedCurrencyReportsOrWrite() async throws {
        try await withReports { workspace, _, reports in
            let euro = try await addProject(workspace, "Euro", currency: "EUR")
            let yen = try await addProject(workspace, "Yen", currency: "JPY")
            let euroTask = try await addTask(workspace, projectID: euro, name: "Euro work")
            let yenTask = try await addTask(workspace, projectID: yen, name: "Yen work")
            for (taskID, start, end) in [(euroTask, Int64(1_704_067_200), Int64(1_704_070_800)),
                                         (yenTask, Int64(1_704_070_800), Int64(1_704_074_400))] {
                let preview = try CorrectionPlanner.preview(.add(id: UUID(), taskID: taskID, startAt: start, endAt: end),
                                                             in: #require(workspace.snapshot))
                _ = try await workspace.enqueueCorrection(.apply(preview)).value
                _ = try await workspace.submit(.editTask(id: taskID, name: taskID == euroTask ? "Euro work" : "Yen work", budgetMinutes: 60),
                                               expectedRevision: try #require(workspace.snapshot).revision)
            }
            let before = try #require(workspace.snapshot)
            let warnings = workspace.budgetWarnings.map(\.id)
            let locale = Locale(identifier: "en_US_POSIX")
            reports.refresh(now: 1_704_110_400, calendar: calendar("UTC"))
            let weekBefore = try #require(reports.week)
            let amountsBefore = reports.weeklyAmounts
            #expect(Set(amountsBefore.map { ReportFormatting.amount($0, locale: locale) }) == Set(["EUR 60.00", "JPY 60"]))
            for allocation in try BudgetRules.allocations(in: before) {
                let used = try workspace.budgetUsage()[allocation.taskID] ?? 0
                _ = ReportFormatting.budgetHours(seconds: used, locale: locale)
                _ = ReportFormatting.budgetBalance(used: used, budget: allocation.limitMinutes, locale: locale)
                _ = ReportFormatting.budgetAllocation(allocated: allocation.allocatedMinutes, budget: allocation.limitMinutes, locale: locale)
            }
            for (projectID, expected) in [(euro, "EUR 60.00"), (yen, "JPY 60")] {
                reports.openProject(projectID)
                reports.refresh(now: 1_704_110_400, calendar: calendar("UTC"))
                let report = try #require(reports.project)
                #expect(report.total.totalSeconds == 3600)
                let amount = try #require(reports.projectAmount)
                #expect(ReportFormatting.amount(amount, locale: locale) == expected)
            }
            reports.backToWeek()
            reports.refresh(now: 1_704_110_400, calendar: calendar("UTC"))
            #expect(reports.week == weekBefore)
            #expect(reports.weeklyAmounts == amountsBefore)
            #expect(workspace.snapshot == before)
            #expect(workspace.budgetWarnings.map(\.id) == warnings)
        }
    }
}

@MainActor struct ScopedReportsPresentationTests {
    @Test func scopeRoutesPreservePeriodOnClearAndRejectCrossProject() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            defer { host.invalidate() }
            let p = try await project(track), other = try await project(track, name: "Other")
            let root = try await task(track, project: p, name: "Root")
            let child = try await task(track, project: p, parent: root, name: "Child")
            let sibling = try await task(track, project: p, name: "Sibling")
            let foreign = try await task(track, project: other, name: "Foreign")
            var opens = 0
            host.installSceneActions(workspace: { opens += 1 }, settings: {})
            let reports = host.reports
            #expect(reports.track === host.track)
            reports.weekAnchor = 1_710_000_000
            reports.includeArchived = true
            host.openProjectReport(projectID: p, scopeTaskID: root)
            #expect(opens == 1 && host.track.destination == .reports)
            #expect(reports.scopeTaskID == root)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            reports.refresh(now: 1_710_000_000, calendar: calendar)
            #expect(Set(try #require(reports.project).tasks.map(\.id)) == Set([root, child]))
            #expect(reports.project?.scopeTask?.id == root)
            reports.period = .thisMonth
            reports.expandedTaskIDs = [root]
            reports.selectedLeafID = child
            for now in 1_710_000_001...1_710_000_003 {
                reports.refresh(now: Int64(now), calendar: calendar)
                #expect(reports.expandedTaskIDs == [root] && reports.selectedLeafID == child)
                #expect(reports.project?.scopeTask?.id == root && reports.error == nil)
            }
            reports.openProject(p, scopeTaskID: foreign)
            #expect(reports.scopeTaskID == root)
            reports.clearTaskFilter()
            #expect(reports.period == .thisMonth && reports.returnToWeek != nil)
            reports.refresh(now: 1_710_000_004, calendar: calendar)
            #expect(Set(try #require(reports.project).tasks.map(\.id)) == Set([root, child, sibling]))
            #expect(reports.project?.scopeTask == nil)
            reports.backToWeek()
            #expect(reports.weekAnchor == 1_710_000_000 && reports.includeArchived)
        }
    }

    @Test func archivedScopeAndProjectionFailureNeverShowStaleResults() async throws {
        try await withTrack { track, _ in
            let p = try await project(track), leaf = try await task(track, project: p)
            _ = try await track.workspace.submit(.setArchived(id: p, archived: true),
                                                  expectedRevision: #require(track.workspace.snapshot).revision)
            let reports = ReportsPresentation(track: track)
            reports.openProject(p, scopeTaskID: leaf)
            #expect(reports.includeArchived && reports.scopeTaskID == leaf)
            let calendar = Calendar(identifier: .gregorian)
            reports.refresh(now: 1_710_000_000, calendar: calendar)
            #expect(reports.project?.scopeTask?.id == leaf)
            reports.applyCustom(first: DateComponents(year: 2024, month: 2, day: 31),
                                last: DateComponents(year: 2024, month: 3, day: 2))
            reports.refresh(now: 1_710_000_000, calendar: calendar)
            #expect(reports.project == nil && reports.projectAmount == nil && reports.taskAmounts.isEmpty)
            #expect(reports.error != nil)
            await track.workspace.close()
            reports.refresh(now: 1_710_000_000, calendar: calendar)
            #expect(reports.project == nil && reports.week == nil)
        }
    }

    @Test func totalTimeDoesNotWrapHoursOrRoundPartialMinutes() {
        #expect(ReportFormatting.totalTime(seconds: 0) == "00:00")
        #expect(ReportFormatting.totalTime(seconds: 59) == "00:00")
        #expect(ReportFormatting.totalTime(seconds: 3661) == "01:01")
        #expect(ReportFormatting.totalTime(seconds: 360_060) == "100:01")
        #expect(ReportFormatting.totalTime(seconds: .max) == "2562047788015215:30")
    }
}
