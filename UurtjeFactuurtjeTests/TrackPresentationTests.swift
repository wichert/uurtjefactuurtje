import Foundation
import Testing
@testable import LibraryStore
@testable import UurtjeFactuurtje

@Suite @MainActor struct TrackPresentationTests {
    @Test func emptyFirstProjectAndStaleSelections() async throws {
        try await withTrack { t, _ in
            #expect(t.projects.isEmpty)
            t.selectedProjectID = UUID(); t.selectedTaskID = UUID(); t.expandedTaskIDs = [UUID()]
            t.reconcile(); #expect(t.selectedProjectID == nil); #expect(t.selectedTaskID == nil); #expect(t.expandedTaskIDs.isEmpty)
            t.editProject()
            guard case .project(let draft) = t.sheet else { Issue.record("Expected first project editor"); return }
            #expect(draft.isNew)
            t.cancelSheet()
            let p = try await project(t)
            t.selectedProjectID = p; t.newTask(projectID: p)
            guard case .task(let next) = t.sheet else { Issue.record("Expected first task"); return }
            #expect(next.projectID == p); #expect(next.isNew)
            #expect(t.workspace.snapshot?.activeTimer == nil)
        }
    }
    @Test func repeatedRevealDefersSheetAndArchivedSelection() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), root = try await task(t, project: p, name: "Root")
            let leaf = try await task(t, project: p, parent: root, name: "Leaf")
            t.editTask(leaf); let token = t.routeToken
            t.search = "hidden"; t.revealTask(leaf); let first = t.reveal?.id
            t.revealTask(leaf)
            #expect(t.reveal?.id != first); #expect(t.routeToken == token); #expect(t.sheet != nil)
            #expect(t.search.isEmpty); #expect(t.expandedTaskIDs.contains(root))
            t.cancelSheet()
            let s = try #require(t.workspace.snapshot)
            _ = try await t.workspace.submit(.setArchived(id: p, archived: true), expectedRevision: s.revision)
            t.showArchived = false; t.reconcile()
            #expect(t.selectedTaskID == leaf); #expect(t.selectedProjectID == p)
            #expect(!t.eligible(leaf)); #expect(!t.canStartFromList(leaf, listFocused: true))
            t.revealTask(leaf); #expect(t.showArchived)
        }
    }
    @Test func filteredRunningIdentityAndDisplayDoNotWrite() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), leaf = try await task(t, project: p)
            _ = try await t.workspace.enqueueTimer(.start(taskID: leaf)).value
            let before = try #require(t.workspace.snapshot)
            let warnings = t.workspace.budgetWarnings.map(\.id)
            t.search = "hidden"; t.selectedProjectID = nil
            #expect(t.path(leaf).contains("Project / Task"))
            #expect(t.ownedStop != nil)
            for _ in 0..<3 { _ = try t.workspace.timerElapsedSeconds(); _ = try t.workspace.budgetUsage() }
            #expect(t.workspace.snapshot == before); #expect(t.workspace.budgetWarnings.map(\.id) == warnings)
            _ = try await t.workspace.enqueueTimer(.stop(expectedEntryID: before.activeTimer?.entryID)).value
        }
    }
    @Test func localDayIntersectionsKeepWholeIdentity() throws {
        var c = Calendar(identifier: .gregorian); c.timeZone = try #require(TimeZone(identifier: "Europe/Amsterdam"))
        for components in [DateComponents(year: 2025, month: 3, day: 30), DateComponents(year: 2025, month: 10, day: 26)] {
            let noon = try #require(c.date(from: components)).addingTimeInterval(12 * 3600)
            let day = try #require(c.dateInterval(of: .day, for: noon))
            let lo = Int64(day.start.timeIntervalSince1970), hi = Int64(day.end.timeIntervalSince1970)
            #expect(hi - lo == (components.month == 3 ? 23 : 25) * 3600)
            let owner = UUID()
            let crossing = TimeEntry(id: UUID(), taskID: owner, startAt: lo - 60, endAt: hi + 60)
            let adjacent = TimeEntry(id: UUID(), taskID: owner, startAt: lo - 120, endAt: lo)
            let s = LibrarySnapshot(schemaVersion: 2, revision: 0, projects: [], tasks: [], entries: [crossing, adjacent], activeTimer: nil, pendingSleepIntervals: [])
            let rows = TrackPresentation.todayEntries(in: s, now: noon, calendar: c)
            #expect(rows == [crossing]); #expect(rows[0].startAt == lo - 60); #expect(rows[0].endAt == hi + 60)
        }
    }
    @Test func routeTokenRejectsLateCompletionAndAcceptedDismissal() async throws {
        try await withTrack { t, _ in
            _ = try await project(t)
            t.editProject(); let token = t.routeToken
            #expect(t.begin(token)); t.cancelSheet(); #expect(t.sheet != nil)
            t.complete(UUID()); #expect(t.acceptedWork)
            t.complete(token, error: EditorError.invalid("disk full"))
            #expect(t.sheet != nil); #expect(!t.acceptedWork); #expect(t.failure != nil)
            t.cancelSheet(); t.reviewTime(); let replacement = t.routeToken
            t.complete(token); #expect(t.routeToken == replacement); #expect(t.sheet != nil)
        }
    }
}
