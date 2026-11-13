import Foundation
import Testing

@testable import LibraryStore
@testable import UurtjeFactuurtje

@Suite @MainActor struct TrackPresentationTests {
    @Test func emptyFirstProjectAndStaleSelections() async throws {
        try await withTrack { track, _ in
            #expect(track.projects.isEmpty)
            track.selectedProjectID = UUID()
            track.selectedTaskID = UUID()
            track.expandedTaskIDs = [UUID()]
            track.reconcile()
            #expect(track.selectedProjectID == nil)
            #expect(track.selectedTaskID == nil)
            #expect(track.expandedTaskIDs.isEmpty)
            track.editProject()
            guard case .project(let draft) = track.sheet else {
                Issue.record("Expected first project editor")
                return
            }
            #expect(draft.isNew)
            track.cancelSheet()
            let projectID = try await project(track)
            track.selectedProjectID = projectID
            track.newTask(projectID: projectID)
            guard case .task(let next) = track.sheet else {
                Issue.record("Expected first task")
                return
            }
            #expect(next.projectID == projectID)
            #expect(next.isNew)
            #expect(track.workspace.snapshot?.activeTimer == nil)
        }
    }
    @Test func repeatedRevealDefersSheetAndArchivedSelection() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let root = try await task(track, project: projectID, name: "Root")
            let leaf = try await task(track, project: projectID, parent: root, name: "Leaf")
            track.editTask(leaf)
            let token = track.routeToken
            track.search = "hidden"
            track.revealTask(leaf)
            let first = track.reveal?.id
            track.revealTask(leaf)
            #expect(track.reveal?.id != first)
            #expect(track.routeToken == token)
            #expect(track.sheet != nil)
            #expect(track.search.isEmpty)
            #expect(track.expandedTaskIDs.contains(root))
            track.cancelSheet()
            let statement = try #require(track.workspace.snapshot)
            _ = try await track.workspace.submit(
                .setArchived(id: projectID, archived: true),
                expectedRevision: statement.revision)
            track.showArchived = false
            track.reconcile()
            #expect(track.selectedTaskID == leaf)
            #expect(track.selectedProjectID == projectID)
            #expect(!track.eligible(leaf))
            #expect(!track.canStartFromList(leaf, listFocused: true))
            track.revealTask(leaf)
            #expect(track.showArchived)
        }
    }
    @Test func filteredRunningIdentityAndDisplayDoNotWrite() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let leaf = try await task(track, project: projectID)
            _ = try await track.workspace.enqueueTimer(.start(taskID: leaf)).value
            let before = try #require(track.workspace.snapshot)
            let warnings = track.workspace.budgetWarnings.map(\.id)
            track.search = "hidden"
            track.selectedProjectID = nil
            #expect(track.path(leaf).contains("Project / Task"))
            #expect(track.ownedStop != nil)
            for _ in 0..<3 {
                _ = try track.workspace.timerElapsedSeconds()
                _ = try track.workspace.budgetUsage()
            }
            #expect(track.workspace.snapshot == before)
            #expect(track.workspace.budgetWarnings.map(\.id) == warnings)
            _ = try await track.workspace.enqueueTimer(.stop(expectedEntryID: before.activeTimer?.entryID)).value
        }
    }
    @Test func localDayIntersectionsKeepWholeIdentity() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Amsterdam"))
        for components in [
            DateComponents(year: 2025, month: 3, day: 30),
            DateComponents(
                year: 2025, month: 10,
                day: 26)
        ] {
            let noon = try #require(calendar.date(from: components)).addingTimeInterval(12 * 3600)
            let day = try #require(calendar.dateInterval(of: .day, for: noon))
            let lowerBound = Int64(day.start.timeIntervalSince1970)
            let upperBound = Int64(day.end.timeIntervalSince1970)
            #expect(upperBound - lowerBound == (components.month == 3 ? 23 : 25) * 3600)
            let owner = UUID()
            let crossing = TimeEntry(id: UUID(), taskID: owner, startAt: lowerBound - 60, endAt: upperBound + 60)
            let adjacent = TimeEntry(id: UUID(), taskID: owner, startAt: lowerBound - 120, endAt: lowerBound)
            let statement = LibrarySnapshot(
                schemaVersion: 2, revision: 0, projects: [], tasks: [],
                entries: [crossing, adjacent], activeTimer: nil, pendingSleepIntervals: [])
            let rows = TrackPresentation.todayEntries(in: statement, now: noon, calendar: calendar)
            #expect(rows == [crossing])
            #expect(rows[0].startAt == lowerBound - 60)
            #expect(rows[0].endAt == upperBound + 60)
        }
    }
    @Test func routeTokenRejectsLateCompletionAndAcceptedDismissal() async throws {
        try await withTrack { track, _ in
            _ = try await project(track)
            track.editProject()
            let token = track.routeToken
            #expect(track.begin(token))
            track.cancelSheet()
            #expect(track.sheet != nil)
            track.complete(UUID())
            #expect(track.acceptedWork)
            track.complete(token, error: EditorError.invalid("disk full"))
            #expect(track.sheet != nil)
            #expect(!track.acceptedWork)
            #expect(track.failure != nil)
            track.cancelSheet()
            track.reviewTime()
            let replacement = track.routeToken
            track.complete(token)
            #expect(track.routeToken == replacement)
            #expect(track.sheet != nil)
        }
    }
}
