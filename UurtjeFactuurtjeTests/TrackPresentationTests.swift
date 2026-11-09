import Foundation
import Testing
@testable import LibraryStore
@testable import UurtjeFactuurtje

func fixtureTemporaryDirectory() -> URL {
    let path = FileManager.default.temporaryDirectory.path
    // /var is a symlink; sandbox container paths already name real directories.
    return URL(fileURLWithPath: path.hasPrefix("/var/") ? "/private" + path : path, isDirectory: true)
}

@MainActor func withTrack(_ body: (TrackPresentation, URL) async throws -> Void) async throws {
    let directory = fixtureTemporaryDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
    let suite = "TrackTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    let model = WorkspaceModel(directory: directory)
    let track = TrackPresentation(workspace: model, defaults: defaults)
    do {
        try await model.open()
        try await body(track, directory)
        await model.close()
    } catch {
        await model.close()
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
        throw error
    }
    try FileManager.default.removeItem(at: directory)
    defaults.removePersistentDomain(forName: suite)
}
@MainActor @discardableResult func project(_ track: TrackPresentation, name: String = "Project") async throws -> UUID {
    let id = UUID(), s = try #require(track.workspace.snapshot)
    _ = try await track.workspace.submit(.createProject(id: id, name: name, rate: 50, currency: "EUR"), expectedRevision: s.revision)
    return id
}
@MainActor @discardableResult func task(_ track: TrackPresentation, project: UUID, parent: UUID? = nil, name: String = "Task") async throws -> UUID {
    let id = UUID(), s = try #require(track.workspace.snapshot)
    _ = try await track.workspace.enqueueTaskCreation(TaskCreationRequest(id: id, projectID: project, parentID: parent, name: name, confirmMigration: false, start: false), expectedRevision: s.revision).value
    return id
}

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
    @Test func deepDuplicateSearchAndVisibleLeafKeyboard() async throws {
        try await withTrack { t, _ in
            let a = try await project(t, name: "A"), b = try await project(t, name: "B")
            let root = try await task(t, project: a, name: "Parent")
            var parent = root
            for n in 0..<32 { parent = try await task(t, project: a, parent: parent, name: "Level \(n)") }
            let leaf = try await task(t, project: a, parent: parent, name: "Duplicate")
            _ = try await task(t, project: b, name: "Duplicate")
            t.selectedProjectID = a; t.selectedTaskID = leaf
            #expect(t.rows(projectID: a).map(\.id) == [root])
            #expect(!t.canStartFromList(leaf, listFocused: true))
            t.search = "A / Parent"
            let rows = t.rows(projectID: a)
            #expect(rows.count == 34); #expect(rows.last?.id == leaf)
            #expect(rows.last?.path.hasPrefix("A / Parent / Level 0") == true)
            #expect(t.expandedTaskIDs.isEmpty)
            #expect(!t.canStartFromList(root, listFocused: true))
            #expect(!t.canStartFromList(leaf, listFocused: false))
            #expect(t.canStartFromList(leaf, listFocused: true))
            t.search = "no match"; #expect(!t.canStartFromList(leaf, listFocused: true))
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
            let s = LibrarySnapshot(schemaVersion: 1, revision: 0, projects: [], tasks: [], entries: [crossing, adjacent], activeTimer: nil, pendingSleepIntervals: [])
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

@Suite @MainActor struct CreationRevealTests {
    @Test(arguments: [false, true])
    func confirmedProjectSelectsEvenWhenEmpty(first: Bool) async throws {
        try await withTrack { t, _ in
            if !first { _ = try await project(t, name: "Existing") }
            t.destination = .reports; t.search = "hidden"; t.selectedTaskID = nil
            t.editProject()
            guard case .project(let d) = t.sheet else { Issue.record("Missing project draft"); return }
            let token = t.routeToken, before = try #require(t.workspace.snapshot)
            #expect(t.begin(token))
            let accepted = t.workspace.enqueueSubmit(.createProject(id: d.id, name: "Created", rate: 0, currency: "EUR"),
                expectedRevision: d.observedRevision, reviewedSnapshot: d.reviewedSnapshot)
            #expect(t.selectedProjectID != d.id && t.destination == .reports)
            let saved = try await accepted.value
            #expect(t.selectedProjectID != d.id)
            t.complete(token)
            #expect(saved.revision == before.revision + 1)
            #expect(t.destination == .track && t.search.isEmpty && t.selectedProjectID == d.id)
            #expect(t.selectedTaskID == nil && t.rows(projectID: d.id).isEmpty)
            #expect(saved.activeTimer == nil && !t.acceptedWork)
            if first {
                guard case .task(let next) = t.sheet else { Issue.record("Missing first-task onboarding"); return }
                #expect(next.isNew && next.projectID == d.id && next.reviewedSnapshot == saved)
            } else { #expect(t.sheet == nil) }
        }
    }

    @Test(arguments: [false, true])
    func createdChildRevealsOnlyAfterCompletionWithoutSecondTimerWrite(start: Bool) async throws {
        try await withTrack { t, _ in
            let p = try await project(t), root = try await task(t, project: p, name: "Root")
            t.workspace.configureTimer(clock: { 100 })
            t.destination = .reports; t.search = "hidden"; t.expandedTaskIDs = []
            t.newTask(projectID: p, parentID: root)
            guard case .task(var d) = t.sheet else { Issue.record("Missing task draft"); return }
            d.name = "Created"; t.updateTaskDraft(d)
            let token = t.routeToken, before = try #require(t.workspace.snapshot)
            #expect(t.begin(token))
            let accepted = t.workspace.enqueueTaskCreation(d.request(start: start), expectedRevision: d.observedRevision, reviewedSnapshot: d.reviewedSnapshot)
            #expect(t.reveal == nil && t.selectedTaskID != d.id)
            let created = try await accepted.value
            #expect(t.reveal == nil && t.destination == .reports)
            t.complete(token)
            #expect(t.sheet == nil && !t.acceptedWork)
            #expect(t.destination == .track && t.search.isEmpty)
            #expect(t.selectedProjectID == p && t.selectedTaskID == d.id)
            #expect(t.expandedTaskIDs.contains(root) && t.reveal?.taskID == d.id)
            #expect(t.rows(projectID: p).contains { $0.id == d.id })
            #expect(created.snapshot.revision == before.revision + 1)
            #expect(t.workspace.snapshot == created.snapshot)
            #expect(created.snapshot.tasks.first { $0.id == d.id }?.budgetSeconds == nil)
            if start {
                let active = try #require(created.snapshot.activeTimer)
                #expect(created.snapshot.entries.first { $0.id == active.entryID }?.taskID == d.id)
                #expect(created.snapshot.entries.first { $0.id == active.entryID }?.startAt == 100)
            } else { #expect(created.snapshot.activeTimer == nil && created.snapshot.entries == before.entries) }
        }
    }

    @Test func lateCompletionCannotRevealOverReplacementOrConsumeItsAcceptance() async throws {
        try await withTrack { t, _ in
            let p = try await project(t)
            t.newTask(projectID: p)
            guard case .task(var d) = t.sheet else { Issue.record("Missing task"); return }
            d.name = "Created"; t.updateTaskDraft(d)
            let old = t.routeToken
            #expect(t.begin(old))
            let created = try await t.workspace.enqueueTaskCreation(d.request(start: false), expectedRevision: d.observedRevision, reviewedSnapshot: d.reviewedSnapshot).value
            t.complete(old)
            let reveal = t.reveal?.id
            t.editProject(p); let replacement = t.routeToken
            t.destination = .reports; t.search = "keep"
            #expect(t.begin(replacement))
            t.complete(old)
            #expect(t.routeToken == replacement && t.sheet?.id == p && t.acceptedWork)
            #expect(t.destination == .reports && t.search == "keep" && t.reveal?.id == reveal)
            #expect(t.workspace.snapshot == created.snapshot)
            t.complete(replacement, error: EditorError.invalid("Keep draft"))
            #expect(t.sheet?.id == p && !t.acceptedWork)
        }
    }

    @Test func failureAndOrdinaryProjectEditDoNotNavigate() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), leaf = try await task(t, project: p)
            t.revealTask(leaf)
            let reveal = t.reveal?.id
            t.destination = .reports; t.search = "keep"; t.editProject(p)
            let token = t.routeToken, before = try #require(t.workspace.snapshot)
            #expect(t.begin(token))
            t.complete(token, error: EditorError.invalid("disk full"))
            #expect(t.sheet?.id == p && t.destination == .reports && t.search == "keep")
            #expect(t.reveal?.id == reveal && t.workspace.snapshot == before)
            #expect(t.begin(token))
            let saved = try await t.workspace.enqueueSubmit(.updateProject(id: p, name: "Edited", rate: 75, currency: "EUR", confirmedPreviousCurrency: nil),
                expectedRevision: before.revision, reviewedSnapshot: before).value
            t.complete(token)
            #expect(t.sheet == nil && !t.acceptedWork)
            #expect(t.destination == .reports && t.search == "keep" && t.reveal?.id == reveal)
            #expect(t.selectedProjectID == p && t.selectedTaskID == leaf && t.workspace.snapshot == saved)
        }
    }
}

@Suite @MainActor struct RevealConsumptionTests {
    @Test func consumedRevealIsNotReplayedByOrdinaryEdit() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), leaf = try await task(t, project: p)
            t.revealTask(leaf)
            let route = t.routeToken
            #expect(t.consumeReveal()?.taskID == leaf)
            #expect(t.routeToken == route && t.sheet == nil)
            #expect(t.reveal == nil && t.consumeReveal() == nil)
            t.editTask(leaf)
            let token = t.routeToken, before = try #require(t.workspace.snapshot)
            #expect(t.begin(token))
            _ = try await t.workspace.enqueueSubmit(.editTask(id: leaf, name: "Edited", budgetSeconds: nil),
                expectedRevision: before.revision, reviewedSnapshot: before).value
            t.complete(token)
            #expect(t.sheet == nil && t.reveal == nil && t.consumeReveal() == nil)
            #expect(t.selectedTaskID == leaf)
        }
    }

    @Test func revealRequestedDuringSheetIsDeferredThenTakenOnce() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), leaf = try await task(t, project: p)
            t.editTask(leaf)
            t.revealTask(leaf)
            let route = t.routeToken, request = try #require(t.reveal)
            #expect(t.consumeReveal() == nil && t.reveal?.id == request.id)
            #expect(t.routeToken == route && t.sheet?.id == leaf)
            t.cancelSheet()
            let dismissedRoute = t.routeToken
            let consumed = try #require(t.consumeReveal())
            #expect(consumed.id == request.id && consumed.taskID == leaf)
            #expect(t.routeToken == dismissedRoute && t.sheet == nil)
            #expect(t.reveal == nil && t.consumeReveal() == nil)
        }
    }

    @Test func createdTaskRevealSurvivesCreationAndDiesBeforeOrdinaryEdit() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), root = try await task(t, project: p, name: "Root")
            t.destination = .reports; t.search = "hidden"
            t.newTask(projectID: p, parentID: root)
            guard case .task(var d) = t.sheet else { Issue.record("Missing task draft"); return }
            d.name = "Created"; t.updateTaskDraft(d)
            let token = t.routeToken
            #expect(t.begin(token))
            let created = try await t.workspace.enqueueTaskCreation(d.request(start: false),
                expectedRevision: d.observedRevision, reviewedSnapshot: d.reviewedSnapshot).value
            t.complete(token)
            #expect(t.destination == .track && t.search.isEmpty && t.selectedTaskID == d.id)
            #expect(t.consumeReveal()?.taskID == d.id)
            #expect(t.reveal == nil && t.workspace.snapshot == created.snapshot)
            t.editTask(d.id)
            let edit = t.routeToken, before = try #require(t.workspace.snapshot)
            #expect(t.begin(edit))
            _ = try await t.workspace.enqueueSubmit(.editTask(id: d.id, name: "Renamed", budgetSeconds: nil),
                expectedRevision: before.revision, reviewedSnapshot: before).value
            t.complete(edit)
            #expect(t.sheet == nil && t.consumeReveal() == nil)
            #expect(t.workspace.snapshot?.tasks.first { $0.id == d.id }?.name == "Renamed")
        }
    }
}
