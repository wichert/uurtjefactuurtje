import Foundation
import Testing
@testable import LibraryStore

private struct ReportFixture {
    let projectID = UUID(), leafID = UUID()

    func project(rate: Decimal = 60, currency: String = "EUR", archived: Bool = false) -> Project {
        Project(id: projectID, name: "Client", hourlyRate: rate, currencyCode: currency, isArchived: archived)
    }

    func row(_ start: Int64, _ end: Int64?, id: UUID = UUID()) -> TimeEntry {
        TimeEntry(id: id, taskID: leafID, startAt: start, endAt: end)
    }

    func state(_ entries: [TimeEntry] = [], active: ActiveTimer? = nil,
               pending: [PendingSleepInterval] = []) -> LibrarySnapshot {
        LibrarySnapshot(schemaVersion: 1, revision: 7, projects: [project()],
            tasks: [TaskRecord(id: leafID, projectID: projectID, name: "Leaf")],
            entries: entries, activeTimer: active, pendingSleepIntervals: pending)
    }
}

private func reportCalendar(_ zone: String = "UTC") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

private func reportDate(_ year: Int, _ month: Int, _ day: Int) -> DateComponents {
    DateComponents(year: year, month: month, day: day)
}

private func reportInstant(_ text: String) -> Int64 {
    Int64(ISO8601DateFormatter().date(from: text)!.timeIntervalSince1970)
}

@Suite struct ReportsTests {
    @Test func calendarPeriodsAndInclusiveCustomDates() throws {
        let calendar = reportCalendar(), now = reportInstant("2024-02-15T12:00:00Z")
        #expect(try ReportCalendar.bounds(for: .allTime, now: now, calendar: calendar) == nil)
        #expect(try ReportCalendar.bounds(for: .thisMonth, now: now, calendar: calendar)
            == ReportBounds(start: reportInstant("2024-02-01T00:00:00Z"), end: reportInstant("2024-03-01T00:00:00Z")))
        #expect(try ReportCalendar.bounds(for: .thisWeek, now: now, calendar: calendar)
            == ReportBounds(start: reportInstant("2024-02-12T00:00:00Z"), end: reportInstant("2024-02-19T00:00:00Z")))
        #expect(try ReportCalendar.bounds(for: .thisWeek, now: now, calendar: calendar, firstWeekday: 1)
            == ReportBounds(start: reportInstant("2024-02-11T00:00:00Z"), end: reportInstant("2024-02-18T00:00:00Z")))
        #expect(try ReportCalendar.bounds(for: .custom(first: reportDate(2024, 2, 28), last: reportDate(2024, 2, 29)),
            now: now, calendar: calendar) == ReportBounds(start: reportInstant("2024-02-28T00:00:00Z"),
                                                        end: reportInstant("2024-03-01T00:00:00Z")))
        #expect(try ReportCalendar.bounds(for: .day(containing: now), now: 0, calendar: calendar)
            == ReportBounds(start: reportInstant("2024-02-15T00:00:00Z"), end: reportInstant("2024-02-16T00:00:00Z")))
    }

    @Test func invalidCalendarInputsFailExplicitly() throws {
        let calendar = reportCalendar()
        for invalid in [reportDate(2023, 2, 29), reportDate(2024, 13, 1), reportDate(2024, 4, 31), DateComponents()] {
            #expect(throws: ReportError.invalidDate) {
                try ReportCalendar.bounds(for: .custom(first: invalid, last: invalid), now: 0, calendar: calendar)
            }
        }
        #expect(throws: ReportError.reversedDates) {
            try ReportCalendar.bounds(for: .custom(first: reportDate(2024, 2, 2), last: reportDate(2024, 2, 1)),
                                      now: 0, calendar: calendar)
        }
        for weekday in [Int.min, 0, 8, Int.max] {
            #expect(throws: ReportError.invalidDate) {
                try ReportCalendar.bounds(for: .thisWeek, now: 0, calendar: calendar, firstWeekday: weekday)
            }
            #expect(throws: ReportError.invalidDate) {
                try ReportProjection.week(in: ReportFixture().state(), containing: 0,
                                          calendar: calendar, firstWeekday: weekday)
            }
        }
        #expect(throws: ReportError.intervalOverflow) { try ReportBounds(start: .min, end: .max) }
        #expect(throws: ReportError.invalidDate) {
            try ReportCalendar.bounds(for: .day(containing: .max), now: 0, calendar: calendar)
        }
    }

    @Test func dstAndSkippedMidnightUseActualDayBoundaries() throws {
        for (anchor, start, end, seconds) in [
            ("2024-03-31T12:00:00Z", "2024-03-30T23:00:00Z", "2024-03-31T22:00:00Z", Int64(23 * 3600)),
            ("2024-10-27T12:00:00Z", "2024-10-26T22:00:00Z", "2024-10-27T23:00:00Z", Int64(25 * 3600))
        ] {
            let bounds = try #require(try ReportCalendar.bounds(for: .day(containing: reportInstant(anchor)), now: 0,
                                                            calendar: reportCalendar("Europe/Amsterdam")))
            #expect(bounds.start == reportInstant(start) && bounds.end == reportInstant(end))
            #expect(bounds.end - bounds.start == seconds)
        }
        let bounds = try #require(try ReportCalendar.bounds(for: .custom(first: reportDate(2018, 11, 4), last: reportDate(2018, 11, 4)),
            now: 0, calendar: reportCalendar("America/Sao_Paulo")))
        #expect(bounds.start == reportInstant("2018-11-04T03:00:00Z"))
        #expect(bounds.end == reportInstant("2018-11-05T02:00:00Z"))
    }

    @Test func lordHoweHalfHourTransitionsAgreeAcrossReports() throws {
        let f = ReportFixture(), calendar = reportCalendar("Australia/Lord_Howe")
        for (date, start, end, seconds) in [
            (reportDate(2024, 4, 7), "2024-04-06T13:00:00Z", "2024-04-07T13:30:00Z", Int64(24 * 3600 + 1800)),
            (reportDate(2024, 10, 6), "2024-10-05T13:30:00Z", "2024-10-06T13:00:00Z", Int64(24 * 3600 - 1800))
        ] {
            let lo = reportInstant(start), hi = reportInstant(end)
            let expected = try ReportBounds(start: lo, end: hi)
            let custom = try ReportCalendar.bounds(for: .custom(first: date, last: date), now: lo, calendar: calendar)
            let day = try ReportCalendar.bounds(for: .day(containing: lo + 12 * 3600), now: lo, calendar: calendar)
            #expect(custom == expected && day == expected)
            let state = f.state([f.row(lo - 60, hi + 60)])
            let week = try ReportProjection.week(in: state, containing: lo + 12 * 3600, calendar: calendar)
            #expect(week.days.count == 7)
            let cell = try #require(week.days.first { $0.date.day == date.day })
            #expect(cell.bounds == expected)
            #expect(cell.total.closedSeconds == seconds && cell.total.provisionalSeconds == 0)
            let drilldown = try ReportProjection.project(f.projectID, in: state, bounds: custom, calendar: calendar)
            #expect(cell.projects[f.projectID] == drilldown.total)
            #expect(drilldown.entriesByLeaf[f.leafID]?.first?.included == (try EntryInterval(startAt: lo, endAt: hi)))
            #expect(week.bounds.end == hi)
            #expect(week.total.closedSeconds == seconds + 60) // Sunday ends the week; the trailing minute is outside it.
            #expect(week.total.provisionalSeconds == 0)
        }
    }

    @Test func apiaKeepsSevenCivilSlotsIncludingWhollySkippedFriday() throws {
        let f = ReportFixture(), calendar = reportCalendar("Pacific/Apia")
        let report = try ReportProjection.week(in: f.state(), containing: reportInstant("2011-12-29T12:00:00Z"), calendar: calendar)
        #expect(report.timeZoneIdentifier == "Pacific/Apia")
        #expect(report.days.map { $0.date.day } == [26, 27, 28, 29, 30, 31, 1])
        #expect(report.days.count == 7)
        #expect(report.days[4].bounds == nil)
        #expect(report.days[4].date.month == 12 && report.days[6].date.month == 1)
        #expect(report.bounds.start == reportInstant("2011-12-26T10:00:00Z"))
        #expect(report.bounds.end == reportInstant("2012-01-01T10:00:00Z"))
        for day in report.days {
            #expect(day.projects[f.projectID] == .zero)
            #expect(day.total == .zero && day.openProjectIDs.isEmpty)
        }
        #expect(throws: ReportError.invalidDate) {
            try ReportCalendar.bounds(for: .custom(first: reportDate(2011, 12, 30), last: reportDate(2011, 12, 30)),
                                      now: 0, calendar: calendar)
        }
    }

    @Test func clippingDropsDisjointAndAdjacentRowsPreservingCommittedIdentity() throws {
        let f = ReportFixture(), calendar = reportCalendar()
        let rows = [f.row(0, 10), f.row(10, 30), f.row(30, 40), f.row(40, 50), f.row(60, 70)]
        let state = f.state(Array(rows.reversed()))
        let report = try ReportProjection.project(f.projectID, in: state, bounds: ReportBounds(start: 20, end: 40), calendar: calendar)
        let included = try #require(report.entriesByLeaf[f.leafID])
        #expect(included.map(\.entry) == [rows[1], rows[2]])
        #expect(included.map(\.id) == [rows[1].id, rows[2].id])
        #expect(included.map(\.seconds) == [10, 10])
        #expect(included[0].included == (try EntryInterval(startAt: 20, endAt: 30)))
        #expect(report.total.closedSeconds == 20 && report.total.provisionalSeconds == 0)
        #expect(!report.hasOpenEntry)
        #expect(try ReportProjection.project(f.projectID, in: state, bounds: nil, calendar: calendar).total.totalSeconds == 60)
        #expect(state == f.state(Array(rows.reversed())))
    }

    @Test func wholeOpenIntervalIsProvisionalWithCheckpointOrAuthorizedLiveEnd() throws {
        let f = ReportFixture(), row = f.row(100, nil), calendar = reportCalendar()
        let state = f.state([f.row(0, 50), row], active: ActiveTimer(entryID: row.id, checkpointAt: 120))
        let frozen = try ReportProjection.project(f.projectID, in: state, bounds: nil, calendar: calendar)
        let live = try ReportProjection.project(f.projectID, in: state, bounds: nil, calendar: calendar, liveEnd: 150)
        #expect(frozen.total.closedSeconds == 50 && frozen.total.provisionalSeconds == 20)
        #expect(live.total.closedSeconds == 50 && live.total.provisionalSeconds == 50)
        #expect(live.entriesByLeaf[f.leafID]?.last?.isProvisional == true)
        #expect(live.hasOpenEntry && frozen.hasOpenEntry)
        let clipped = try ReportProjection.project(f.projectID, in: state, bounds: ReportBounds(start: 110, end: 140),
                                                   calendar: calendar, liveEnd: 150)
        #expect(clipped.total.provisionalSeconds == 30 && clipped.total.closedSeconds == 0)
        #expect(state.activeTimer?.checkpointAt == 120 && state.revision == 7)
        #expect(throws: ReportError.invalidActiveEntry) {
            try ReportProjection.project(f.projectID, in: state, bounds: nil, calendar: calendar, liveEnd: 119)
        }
        for invalid in [f.state([row]), f.state([row], active: ActiveTimer(entryID: UUID(), checkpointAt: 120)),
                        f.state([row], active: ActiveTimer(entryID: row.id, checkpointAt: 99))] {
            #expect(throws: ReportError.invalidActiveEntry) {
                try ReportProjection.project(f.projectID, in: invalid, bounds: nil, calendar: calendar)
            }
        }
    }

    @Test func zeroOpenHasRowAndWeeklyMarkerButNoInventedInterval() throws {
        let f = ReportFixture(), start = reportInstant("2024-03-31T12:00:00Z"), calendar = reportCalendar("Europe/Amsterdam")
        let row = f.row(start, nil), state = f.state([row], active: ActiveTimer(entryID: row.id, checkpointAt: start))
        let report = try ReportProjection.project(f.projectID, in: state, bounds: nil, calendar: calendar)
        let visible = try #require(report.entriesByLeaf[f.leafID]?.first)
        #expect(visible.id == row.id && visible.included == nil && visible.seconds == 0 && visible.isProvisional)
        #expect(report.total == .zero && report.hasOpenEntry)
        let week = try ReportProjection.week(in: state, containing: start, calendar: calendar)
        #expect(week.hasOpenEntry && week.total == .zero)
        #expect(week.days.last?.openProjectIDs == [f.projectID])
        let sunday = try #require(week.days.last?.bounds)
        #expect(sunday.end - sunday.start == 23 * 3600)
        let excluded = try ReportProjection.project(f.projectID, in: state, bounds: ReportBounds(start: start - 10, end: start), calendar: calendar)
        #expect(!excluded.hasOpenEntry && (excluded.entriesByLeaf[f.leafID] ?? []).isEmpty)
    }

    @Test func deepHierarchyRollsOnceAndSeparatesLifetimeBudgetFromPeriod() throws {
        let f = ReportFixture(), chain = (0..<40).map { _ in UUID() }, unused = UUID()
        let tasks = chain.enumerated().map { index, id in
            TaskRecord(id: id, projectID: f.projectID, parentTaskID: index == 0 ? nil : chain[index - 1],
                       name: "Level \(index)", budgetSeconds: index == 0 ? 100 : nil,
                       lastWarnedThreshold: index == 0 ? .eighty : .none)
        } + [TaskRecord(id: unused, projectID: f.projectID, name: "Unused")]
        let rows = [TimeEntry(id: UUID(), taskID: chain.last!, startAt: 0, endAt: 60),
                    TimeEntry(id: UUID(), taskID: chain.last!, startAt: 100, endAt: 130)]
        let state = LibrarySnapshot(schemaVersion: 1, revision: 9, projects: [f.project()], tasks: tasks,
                                   entries: rows, activeTimer: nil, pendingSleepIntervals: [])
        let before = state
        let report = try ReportProjection.project(f.projectID, in: state, bounds: ReportBounds(start: 100, end: 130), calendar: reportCalendar())
        #expect(report.total.totalSeconds == 30)
        for id in chain {
            #expect(report.taskTotals[id]?.totalSeconds == 30)
            #expect(report.lifetimeUsage[id] == 90)
        }
        #expect(report.taskTotals[unused] == .zero && report.lifetimeUsage[unused] == 0)
        #expect(Set(report.tasks.map(\.id)) == Set(tasks.map(\.id)))
        #expect(report.displayBands[chain[0]] == .eighty)
        #expect(report.entriesByLeaf[chain.last!]?.map(\.id) == [rows[1].id])
        #expect(state == before && report.tasks.first(where: { $0.id == chain[0] })?.lastWarnedThreshold == .eighty)
    }

    @Test func weeklyClippingAgreesWithDrilldownAndArchiveVisibility() throws {
        let f = ReportFixture(), archived = Project(id: UUID(), name: "Archive", hourlyRate: 1, currencyCode: "USD", isArchived: true)
        let archivedTask = TaskRecord(id: UUID(), projectID: archived.id, name: "Old")
        let midnight = reportInstant("2024-04-02T00:00:00Z")
        let state = LibrarySnapshot(schemaVersion: 1, revision: 0, projects: [f.project(), archived],
            tasks: [TaskRecord(id: f.leafID, projectID: f.projectID, name: "Leaf"), archivedTask],
            entries: [f.row(midnight - 10, midnight + 20), TimeEntry(id: UUID(), taskID: archivedTask.id, startAt: midnight + 20, endAt: midnight + 50)],
            activeTimer: nil, pendingSleepIntervals: [])
        let week = try ReportProjection.week(in: state, containing: midnight, calendar: reportCalendar())
        #expect(week.projects.map(\.id) == [f.projectID] && week.total.totalSeconds == 30)
        #expect(week.days[0].total.totalSeconds == 10 && week.days[1].total.totalSeconds == 20)
        for day in week.days {
            let drilldown = try ReportProjection.project(f.projectID, in: state, bounds: day.bounds, calendar: reportCalendar())
            #expect(day.projects[f.projectID] == drilldown.total)
        }
        let all = try ReportProjection.week(in: state, containing: midnight, calendar: reportCalendar(), includeArchived: true)
        #expect(all.projects.map(\.id) == [archived.id, f.projectID])
        #expect(all.total.totalSeconds == 60 && all.projectTotals[archived.id]?.totalSeconds == 30)
        #expect(all.days.allSatisfy { $0.projects.count == 2 })
        let empty = try ReportProjection.week(in: f.state(), containing: midnight, calendar: reportCalendar())
        #expect(empty.days.count == 7 && empty.total == .zero && empty.projectTotals[f.projectID] == .zero)
        let noProjects = LibrarySnapshot(schemaVersion: 1, revision: 0, projects: [], tasks: [], entries: [], activeTimer: nil, pendingSleepIntervals: [])
        #expect(try ReportProjection.week(in: noProjects, containing: midnight, calendar: reportCalendar()).days.count == 7)
        #expect(try ReportProjection.project(f.projectID, in: f.state(), bounds: nil, calendar: reportCalendar()).total == .zero)
    }

    @Test func malformedHierarchyMissingProjectAndDurationOverflowAreErrors() throws {
        let f = ReportFixture(), calendar = reportCalendar()
        #expect(throws: ReportError.unavailableProject) {
            try ReportProjection.project(UUID(), in: f.state(), bounds: nil, calendar: calendar)
        }
        for parent in [f.leafID, UUID()] {
            let invalid = LibrarySnapshot(schemaVersion: 1, revision: 0, projects: [f.project()],
                tasks: [TaskRecord(id: f.leafID, projectID: f.projectID, parentTaskID: parent, name: "Invalid")],
                entries: [], activeTimer: nil, pendingSleepIntervals: [])
            #expect(throws: ReportError.invalidHierarchy) {
                try ReportProjection.project(f.projectID, in: invalid, bounds: nil, calendar: calendar)
            }
        }
        for rows in [[f.row(.min, .max)], [f.row(.min, -1), f.row(-1, 0)]] {
            #expect(throws: ReportError.intervalOverflow) {
                try ReportProjection.project(f.projectID, in: f.state(rows), bounds: nil, calendar: calendar)
            }
        }
    }

    @Test func exactCurrencyPrecisionsTiesNearTiesAndCurrentRates() throws {
        let f = ReportFixture()
        for (currency, rate, seconds, minor, digits) in [
            ("EUR", "18", Int64(1), "1", 2), ("USD", "17.999999999999999999999999999999999999", 1, "0", 2),
            ("USD", "18.000000000000000000000000000000000001", 1, "1", 2),
            ("JPY", "1800", 1, "1", 0), ("KWD", "1.8", 1, "1", 3),
            ("EUR", "0", Int64.max, "0", 2), ("EUR", "60", 3600, "6000", 2),
            ("USD", "60", 3600, "6000", 2), ("JPY", "60", 3600, "60", 0), ("KWD", "60", 3600, "60000", 3)
        ] {
            let project = f.project(rate: try #require(Decimal(string: rate, locale: Locale(identifier: "en_US_POSIX"))), currency: currency)
            let amount = try ReportProjection.amount(seconds: seconds, project: project)
            #expect(amount.currencyCode == currency && amount.minorUnits == minor && amount.fractionDigits == digits)
        }
        let large = f.project(rate: try #require(Decimal(string: "12345678901234567890123456789012345678")))
        #expect(try ReportProjection.amount(seconds: .max, project: large).minorUnits
            == "3163021932045414083335385083333538508102453247718761449")
        #expect(throws: ReportError.unknownCurrency) {
            try ReportProjection.amount(seconds: 3600, project: f.project(currency: "ZZZ"))
        }
        #expect(throws: ReportError.moneyOverflow) {
            try ReportProjection.amount(seconds: -1, project: f.project())
        }
        #expect(throws: ReportError.moneyOverflow) {
            try ReportProjection.amount(seconds: 1, project: f.project(rate: .nan))
        }
    }

    @Test func rateAndCurrencyEditsRecalculateUnchangedHistory() throws {
        let f = ReportFixture(), original = f.state([f.row(0, 3600)])
        let changed = LibrarySnapshot(schemaVersion: original.schemaVersion, revision: original.revision + 1,
            projects: [f.project(rate: 120, currency: "JPY")], tasks: original.tasks,
            entries: original.entries, activeTimer: nil, pendingSleepIntervals: [])
        let old = try ReportProjection.project(f.projectID, in: original, bounds: nil, calendar: reportCalendar())
        let new = try ReportProjection.project(f.projectID, in: changed, bounds: nil, calendar: reportCalendar())
        #expect(old.total == new.total && old.entriesByLeaf == new.entriesByLeaf)
        let oldAmount = try ReportProjection.amount(seconds: old.total.totalSeconds, project: old.project)
        let newAmount = try ReportProjection.amount(seconds: new.total.totalSeconds, project: new.project)
        #expect(oldAmount.currencyCode == "EUR" && oldAmount.minorUnits == "6000")
        #expect(newAmount.currencyCode == "JPY" && newAmount.minorUnits == "120")
    }

    @Test func currencyGroupsRoundOnceFromUnroundedSecondsAndNeverMixCurrencies() throws {
        let projects = [Project(id: UUID(), name: "B", hourlyRate: 18, currencyCode: "USD"),
                        Project(id: UUID(), name: "A", hourlyRate: 18, currencyCode: "EUR"),
                        Project(id: UUID(), name: "C", hourlyRate: 18, currencyCode: "EUR"),
                        Project(id: UUID(), name: "D", hourlyRate: 1800, currencyCode: "JPY")]
        let tasks = projects.map { TaskRecord(id: UUID(), projectID: $0.id, name: "Task") }
        let state = LibrarySnapshot(schemaVersion: 1, revision: 0, projects: projects, tasks: tasks,
            entries: tasks.enumerated().map { index, task in
                TimeEntry(id: UUID(), taskID: task.id, startAt: Int64(index), endAt: Int64(index + 1))
            }, activeTimer: nil, pendingSleepIntervals: [])
        let week = try ReportProjection.week(in: state, containing: 0, calendar: reportCalendar())
        let amounts = try ReportProjection.amounts(totals: week.projectTotals, projects: week.projects)
        #expect(amounts.map(\.currencyCode) == ["EUR", "JPY", "USD"])
        #expect(amounts.map(\.minorUnits) == ["1", "1", "1"])
        #expect(try ReportProjection.amount(seconds: 1, project: projects[1]).minorUnits == "1")
        #expect(try ReportProjection.amount(seconds: 1, project: projects[2]).minorUnits == "1")
        #expect(try ReportProjection.amounts(totals: [:], projects: []).isEmpty)
    }

    @Test func pendingSleepExcludedUntilIncludeCommitsAndSkipAddsNothing() throws {
        let f = ReportFixture(), calendar = reportCalendar(), open = f.row(50, nil)
        let known = PendingSleepInterval(id: UUID(), taskID: f.leafID, sleepAt: 10, wakeAt: 20)
        let unknown = PendingSleepInterval(id: UUID(), taskID: f.leafID, sleepAt: 30, wakeAt: nil)
        let state = f.state([f.row(0, 10), open], active: ActiveTimer(entryID: open.id, checkpointAt: 60), pending: [known])
        let unknownState = f.state([f.row(0, 10)], pending: [unknown])
        let unknownReport = try ReportProjection.project(f.projectID, in: unknownState, bounds: nil, calendar: calendar)
        #expect(unknownReport.total.closedSeconds == 10 && unknownReport.total.provisionalSeconds == 0)
        #expect(unknownState.pendingSleepIntervals == [unknown])
        let before = state
        let pendingReport = try ReportProjection.project(f.projectID, in: state, bounds: nil, calendar: calendar, liveEnd: 70)
        #expect(pendingReport.total.closedSeconds == 10 && pendingReport.total.provisionalSeconds == 20)
        #expect(pendingReport.lifetimeUsage[f.leafID] == 30)
        let include = try TimeReviewMutation.plan(.include(SleepPlanner.include(known, endAt: nil, in: state)),
                                                 receipt: nil, in: state, now: 100).mutation
        let skip = try TimeReviewMutation.plan(.skip(SleepPlanner.skip(known, in: state)), receipt: nil, in: state, now: 100).mutation
        func applying(_ mutation: TimeReviewMutation) -> LibrarySnapshot {
            let removed = Set(mutation.entries.before.map(\.id))
            return LibrarySnapshot(schemaVersion: state.schemaVersion, revision: state.revision + 1,
                projects: state.projects, tasks: state.tasks,
                entries: state.entries.filter { !removed.contains($0.id) } + mutation.entries.after,
                activeTimer: state.activeTimer,
                pendingSleepIntervals: state.pendingSleepIntervals.filter { $0.id != mutation.removePending?.id })
        }
        let includedState = applying(include), skippedState = applying(skip)
        let included = try ReportProjection.project(f.projectID, in: includedState, bounds: nil, calendar: calendar, liveEnd: 70)
        let skipped = try ReportProjection.project(f.projectID, in: skippedState, bounds: nil, calendar: calendar, liveEnd: 70)
        #expect(included.total.closedSeconds == 20 && included.total.provisionalSeconds == 20)
        #expect(skipped.total == pendingReport.total)
        #expect(includedState.pendingSleepIntervals.isEmpty && skippedState.pendingSleepIntervals.isEmpty)
        #expect(state == before)
    }
}
