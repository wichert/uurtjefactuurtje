import Foundation
import Testing

@testable import LibraryStore
@testable import UurtjeFactuurtje

@MainActor struct ScopedReportsPresentationTests {
    @Test func scopeRoutesPreservePeriodOnClearAndRejectCrossProject() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            defer { host.invalidate() }
            let projectID = try await project(track)
            let other = try await project(track, name: "Other")
            let root = try await task(track, project: projectID, name: "Root")
            let child = try await task(track, project: projectID, parent: root, name: "Child")
            let sibling = try await task(track, project: projectID, name: "Sibling")
            let foreign = try await task(track, project: other, name: "Foreign")
            var opens = 0
            host.installSceneActions(workspace: { opens += 1 }, settings: {})
            let reports = host.reports
            #expect(reports.track === host.track)
            reports.weekAnchor = 1_710_000_000
            reports.includeArchived = true
            host.openProjectReport(projectID: projectID, scopeTaskID: root)
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
            reports.openProject(projectID, scopeTaskID: foreign)
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
            let projectID = try await project(track)
            let leaf = try await task(track, project: projectID)
            _ = try await track.workspace.submit(
                .setArchived(id: projectID, archived: true),
                expectedRevision: #require(track.workspace.snapshot).revision)
            let reports = ReportsPresentation(track: track)
            reports.openProject(projectID, scopeTaskID: leaf)
            #expect(reports.includeArchived && reports.scopeTaskID == leaf)
            let calendar = Calendar(identifier: .gregorian)
            reports.refresh(now: 1_710_000_000, calendar: calendar)
            #expect(reports.project?.scopeTask?.id == leaf)
            reports.applyCustom(
                first: DateComponents(year: 2024, month: 2, day: 31),
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
