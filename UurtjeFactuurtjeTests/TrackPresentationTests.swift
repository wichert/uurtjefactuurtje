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
            #expect(created.snapshot.tasks.first { $0.id == d.id }?.budgetMinutes == nil)
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
            let request = try #require(t.reveal)
            #expect(request.taskID == leaf)
            t.completeReveal(requestID: request.id)
            #expect(t.routeToken == route && t.sheet == nil)
            t.completeReveal(requestID: request.id)
            #expect(t.reveal == nil)
            t.editTask(leaf)
            let token = t.routeToken, before = try #require(t.workspace.snapshot)
            #expect(t.begin(token))
            _ = try await t.workspace.enqueueSubmit(.editTask(id: leaf, name: "Edited", budgetMinutes: nil),
                expectedRevision: before.revision, reviewedSnapshot: before).value
            t.complete(token)
            t.completeReveal(requestID: request.id)
            #expect(t.sheet == nil && t.reveal == nil)
            #expect(t.selectedTaskID == leaf)
        }
    }

    @Test func revealRequestedDuringSheetIsDeferredThenTakenOnce() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), leaf = try await task(t, project: p)
            t.editTask(leaf)
            t.revealTask(leaf)
            let route = t.routeToken, request = try #require(t.reveal)
            t.completeReveal(requestID: request.id)
            #expect(t.reveal?.id == request.id)
            #expect(t.routeToken == route && t.sheet?.id == leaf)
            t.cancelSheet()
            let dismissedRoute = t.routeToken
            #expect(t.reveal?.id == request.id && t.reveal?.taskID == leaf)
            t.completeReveal(requestID: request.id)
            #expect(t.routeToken == dismissedRoute && t.sheet == nil)
            t.completeReveal(requestID: request.id)
            #expect(t.reveal == nil)
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
            let request = try #require(t.reveal)
            #expect(request.taskID == d.id)
            t.completeReveal(requestID: request.id)
            #expect(t.reveal == nil && t.workspace.snapshot == created.snapshot)
            t.editTask(d.id)
            let edit = t.routeToken, before = try #require(t.workspace.snapshot)
            #expect(t.begin(edit))
            _ = try await t.workspace.enqueueSubmit(.editTask(id: d.id, name: "Renamed", budgetMinutes: nil),
                expectedRevision: before.revision, reviewedSnapshot: before).value
            t.complete(edit)
            t.completeReveal(requestID: request.id)
            #expect(t.sheet == nil && t.reveal == nil)
            #expect(t.workspace.snapshot?.tasks.first { $0.id == d.id }?.name == "Renamed")
        }
    }
}

@Suite @MainActor struct TrackOutlineSlice3Tests {
    @Test func rowIdentitySelectionAndLegacyWritesStayCoherent() async throws {
        try await withTrack { t, _ in
            let p = try await project(t, name: "A")
            let q = try await project(t, name: "B")
            let leaf = try await task(t, project: p)
            t.selectedRow = .task(leaf)
            #expect(t.selectedTaskID == leaf && t.selectedProjectID == p)
            t.selectedProjectID = p
            #expect(t.selectedRow == .task(leaf))
            t.selectedProjectID = q
            #expect(t.selectedRow == .project(q) && t.selectedTaskID == nil)
            t.selectedTaskID = leaf
            #expect(t.selectedRow == .task(leaf) && t.selectedProjectID == p)
            t.selectedTaskID = nil
            #expect(t.selectedRow == .project(p))
            t.selectedRow = .task(UUID())
            #expect(t.selectedRow == .project(p))
            t.selectedProjectID = nil
            #expect(t.selectedRow == nil && t.selectedTaskID == nil)
            t.selectedTaskID = UUID()
            t.expandedProjectIDs = [p, UUID()]
            t.reconcile()
            #expect(t.selectedRow == nil)
            #expect(t.expandedProjectIDs == [p])
            #expect(TrackRowID.project(p) != TrackRowID.task(p))
        }
    }

    @Test func nestedSearchKeepsAncestorsStructuralLeavesAndExpansion() async throws {
        try await withTrack { t, _ in
            let p = try await project(t, name: "Client")
            let root = try await task(t, project: p, name: "Parent")
            let match = try await task(t, project: p, parent: root, name: "Needle")
            _ = try await task(t, project: p, parent: root, name: "Other")
            let empty = try await project(t, name: "Empty")
            let outline = t.outlineRows()
            let parent = try #require(outline.first { $0.id == .project(p) }?.children.first)
            #expect(parent.id == .task(root) && !parent.isLeafTask && parent.children.count == 2)
            #expect(parent.path == "Client / Parent" && !parent.isArchived)
            #expect(outline.first { $0.id == .project(empty) }?.isLeafTask == false)
            t.selectedRow = .task(match)
            #expect(!t.isVisible(.task(match)))
            #expect(!t.canStartFromList(match, listFocused: true))
            t.search = "Needle"
            let filtered = t.outlineRows()
            let projectRow = try #require(filtered.first)
            let rootRow = try #require(projectRow.children.first)
            #expect(filtered.count == 1 && projectRow.id == .project(p))
            #expect(rootRow.id == .task(root) && !rootRow.isLeafTask)
            #expect(rootRow.children.map(\.id) == [.task(match)])
            #expect(rootRow.children.first?.isLeafTask == true)
            #expect(t.isVisible(.task(match)))
            #expect(t.canStartFromList(match, listFocused: true))
            #expect(!t.canStartFromList(match, listFocused: false))
            #expect(t.expandedProjectIDs.isEmpty && t.expandedTaskIDs.isEmpty)
            t.search = "Empty"
            #expect(t.outlineRows().map(\.id) == [.project(empty)])
            t.search = "Client"
            #expect(t.outlineRows().first?.children.contains { $0.id == .task(root) } == true)
            t.search = ""
            #expect(!t.isVisible(.task(match)))
            #expect(t.selectedRow == .task(match))
            t.expandedProjectIDs.insert(p)
            #expect(t.isVisible(.task(root)) && !t.isVisible(.task(match)))
            t.expandedTaskIDs.insert(root)
            #expect(t.isVisible(.task(match)))
        }
    }

    @Test func expansionPersistsAndArchivedRevealRemainsSheetDeferred() async throws {
        try await withTrack { t, _ in
            let p = try await project(t)
            let root = try await task(t, project: p, name: "Root")
            let leaf = try await task(t, project: p, parent: root, name: "Leaf")
            let before = try #require(t.workspace.snapshot)
            _ = try await t.workspace.submit(.setArchived(id: p, archived: true), expectedRevision: before.revision)
            t.selectedRow = .task(leaf)
            t.reconcile()
            #expect(t.outlineRows().isEmpty && t.selectedRow == .task(leaf))
            #expect(!t.eligible(leaf))
            t.editTask(leaf)
            let token = t.routeToken
            t.revealTask(leaf)
            let first = try #require(t.reveal?.id)
            t.revealTask(leaf)
            #expect(t.reveal?.id != first && t.routeToken == token)
            let current = try #require(t.reveal?.id)
            t.completeReveal(requestID: first)
            #expect(t.reveal?.id == current)
            #expect(t.showArchived && t.expandedProjectIDs.contains(p) && t.expandedTaskIDs.contains(root))
            #expect(t.isVisible(.task(leaf)) && t.reveal != nil)
            let row = try #require(t.outlineRows().first)
            #expect(row.isArchived && row.children.first?.children.first?.isArchived == true)
            t.cancelSheet()
            #expect(t.reveal?.taskID == leaf && t.reveal != nil)
            t.revealTask(leaf)
            let mounted = try #require(t.reveal?.id)
            t.completeReveal(requestID: mounted)
            #expect(t.reveal == nil)

            let suite = "TrackSlice3.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(UUID().uuidString, forKey: "track.project")
            defaults.set(leaf.uuidString, forKey: "track.task")
            let a = TrackPresentation(workspace: t.workspace, defaults: defaults)
            a.reconcile()
            #expect(a.selectedRow == .task(leaf) && a.selectedProjectID == p)
            a.expandedProjectIDs = [p]
            a.expandedTaskIDs = [root]
            a.search = "Leaf"
            _ = a.outlineRows()
            let b = TrackPresentation(workspace: t.workspace, defaults: defaults)
            #expect(b.expandedProjectIDs == [p] && b.expandedTaskIDs == [root])
            #expect(b.selectedRow == .task(leaf) && b.selectedProjectID == p)
        }
    }

    @Test func closedAndLiveRollUpOnceAndCheckpointSurvivesRollbackAndSleep() async throws {
        try await withTrack { t, _ in
            let p = try await project(t)
            let root = try await task(t, project: p, name: "Root")
            let leaf = try await task(t, project: p, parent: root, name: "Leaf")
            let empty = try await project(t, name: "Empty")
            t.workspace.configureTimer(clock: { 100 })
            _ = try await t.workspace.enqueueTimer(.start(taskID: leaf)).value
            t.workspace.configureTimer(clock: { 160 })
            let first = try #require(t.workspace.snapshot?.activeTimer)
            _ = try await t.workspace.enqueueTimer(.stop(expectedEntryID: first.entryID)).value
            t.workspace.configureTimer(clock: { 200 })
            _ = try await t.workspace.enqueueTimer(.start(taskID: leaf)).value
            t.workspace.configureTimer(clock: { 230 })
            _ = try await t.workspace.enqueueTimer(.checkpoint).value
            t.workspace.configureTimer(clock: { 260 })
            let before = try #require(t.workspace.snapshot)
            let warnings = t.workspace.budgetWarnings.map(\.id)
            let totals = try t.projectTaskTotals()
            #expect(totals[.task(leaf)] == 120 && totals[.task(root)] == 120)
            #expect(totals[.project(p)] == 120 && totals[.project(empty)] == 0)
            t.search = "hidden"
            #expect(try t.projectTaskTotals() == totals)
            #expect(t.workspace.snapshot == before && t.workspace.budgetWarnings.map(\.id) == warnings)
            t.workspace.configureTimer(clock: { 220 })
            #expect(try t.workspace.trackLiveEnd() == nil)
            #expect(try t.projectTaskTotals()[.project(p)] == 90)
            t.workspace.configureTimer(clock: { 300 })
            _ = t.workspace.timerLifecycleGate.latchSleep()
            #expect(try t.workspace.trackLiveEnd() == nil)
            #expect(try t.projectTaskTotals()[.task(leaf)] == 90)
            #expect(t.workspace.snapshot == before)
        }
    }

    @Test func wakePendingIsExcludedAndRestoredActiveUsesCheckpoint() async throws {
        try await withTrack { t, _ in
            let p = try await project(t)
            let leaf = try await task(t, project: p)
            t.workspace.configureTimer(clock: { 100 })
            _ = try await t.workspace.enqueueTimer(.start(taskID: leaf)).value
            t.workspace.configureTimer(clock: { 150 })
            let generation = t.workspace.timerLifecycleGate.latchSleep()
            await t.workspace.enqueueSleepObservation(generation: generation).value
            #expect(t.workspace.snapshot?.pendingSleepIntervals.count == 1)
            #expect(try t.projectTaskTotals()[.project(p)] == 50)
            t.workspace.configureTimer(clock: { 300 })
            await t.workspace.enqueueWakeObservation(generation: generation, observedAt: 300).value
            t.workspace.configureTimer(clock: { 330 })
            _ = try await t.workspace.enqueueTimer(.checkpoint).value
            t.workspace.configureTimer(clock: { 350 })
            #expect(try t.projectTaskTotals()[.project(p)] == 100)
            #expect(t.workspace.snapshot?.pendingSleepIntervals.first?.wakeAt == 300)
            await t.workspace.close()
            try await t.workspace.open()
            #expect(t.workspace.timerStatus == .reviewRequired)
            #expect(try t.workspace.trackLiveEnd() == nil)
            #expect(try t.projectTaskTotals()[.project(p)] == 80)
        }
    }

    @Test func checkedDurationAndAllRollupLevelsFailWithoutWrapping() async throws {
        try await withTrack { t, _ in
            let p = try await project(t)
            let root = try await task(t, project: p, name: "Root")
            let a = try await task(t, project: p, parent: root, name: "A")
            let b = try await task(t, project: p, parent: root, name: "B")
            let base = try #require(t.workspace.snapshot)
            func snapshot(tasks: [TaskRecord], entries: [TimeEntry], active: ActiveTimer? = nil) -> LibrarySnapshot {
                LibrarySnapshot(schemaVersion: 2, revision: base.revision, projects: base.projects,
                    tasks: tasks, entries: entries, activeTimer: active, pendingSleepIntervals: [])
            }
            let huge = TimeEntry(id: UUID(), taskID: a, startAt: 0, endAt: Int64.max)
            let one = TimeEntry(id: UUID(), taskID: b, startAt: 0, endAt: 1)
            let parentOverflow = snapshot(tasks: base.tasks, entries: [huge, one])
            #expect(throws: ReportError.intervalOverflow) {
                try TrackPresentation.projectTaskTotals(in: parentOverflow, liveEnd: nil)
            }
            let sameLeaf = TimeEntry(id: UUID(), taskID: a, startAt: 0, endAt: 1)
            #expect(throws: ReportError.intervalOverflow) {
                try TrackPresentation.projectTaskTotals(in: snapshot(tasks: base.tasks, entries: [huge, sameLeaf]), liveEnd: nil)
            }
            let roots = [TaskRecord(id: a, projectID: p, name: "A"), TaskRecord(id: b, projectID: p, name: "B")]
            #expect(throws: ReportError.intervalOverflow) {
                try TrackPresentation.projectTaskTotals(in: snapshot(tasks: roots, entries: [huge, one]), liveEnd: nil)
            }
            let bad = TimeEntry(id: UUID(), taskID: a, startAt: Int64.min, endAt: Int64.max)
            #expect(throws: ReportError.intervalOverflow) {
                try TrackPresentation.projectTaskTotals(in: snapshot(tasks: roots, entries: [bad]), liveEnd: nil)
            }
            let open = TimeEntry(id: UUID(), taskID: a, startAt: 10, endAt: nil)
            let active = ActiveTimer(entryID: open.id, checkpointAt: 10)
            let zero = snapshot(tasks: roots, entries: [open], active: active)
            #expect(try TrackPresentation.projectTaskTotals(in: zero, liveEnd: nil)[.task(a)] == 0)
            #expect(throws: ReportError.invalidActiveEntry) {
                try TrackPresentation.projectTaskTotals(in: zero, liveEnd: 9)
            }
        }
    }
}

extension TrackOutlineSlice3Tests {
    @Test func hiddenOrCollapsedSelectionDoesNotEnableContextualCreation() async throws {
        try await withTrack { t, _ in
            let p = try await project(t)
            let leaf = try await task(t, project: p)
            t.selectedTaskID = leaf
            #expect(t.selectedRow.map { t.isVisible($0) } == false)
            t.expandedProjectIDs = [p]
            #expect(t.selectedRow.map { t.isVisible($0) } == true)
            t.search = "No match"
            #expect(t.selectedRow.map { t.isVisible($0) } == false)
            t.search = ""
            #expect(t.selectedRow.map { t.isVisible($0) } == true)
        }
    }
}

extension TrackOutlineSlice3Tests {
    @Test func collapsedProjectAndTaskBothGuardKeyboardStart() async throws {
        try await withTrack { t, _ in
            let p = try await project(t, name: "Project")
            var parent = try await task(t, project: p, name: "Task 0")
            for index in 1..<34 {
                parent = try await task(t, project: p, parent: parent, name: "Task \(index)")
            }
            t.selectedTaskID = parent
            #expect(!t.canStartFromList(parent, listFocused: true))
            t.expandedProjectIDs = [p]
            #expect(!t.isVisible(.task(parent)))
            #expect(!t.canStartFromList(parent, listFocused: true))
            var row = t.outlineRows().first?.children.first
            var prefix: [UUID] = []
            while let current = row, current.id != .task(parent) {
                guard case .task(let id) = current.id else { break }
                prefix.append(id)
                row = current.children.first
            }
            #expect(prefix.count == 33)
            t.expandedTaskIDs = Set(prefix)
            #expect(t.isVisible(.task(parent)))
            #expect(t.canStartFromList(parent, listFocused: true))
            #expect(!t.canStartFromList(parent, listFocused: false))
            t.expandedTaskIDs = Set(prefix.dropLast())
            #expect(!t.isVisible(.task(parent)))
            #expect(!t.canStartFromList(parent, listFocused: true))
        }
    }

    @Test func outlineCacheSurvivesExpansionAndInvalidatesQueryArchiveAndRevision() async throws {
        try await withTrack { t, _ in
            let p = try await project(t, name: "Client")
            let leaf = try await task(t, project: p, name: "Alpha")
            let first = t.outlineRows()
            t.expandedProjectIDs = [p]
            t.expandedTaskIDs = [leaf]
            let cached = t.outlineRows()
            #expect(cached.count == first.count && cached[0].path == first[0].path)
            #expect(cached[0].children.map(\.id) == first[0].children.map(\.id))
            t.search = "Alpha"
            #expect(t.outlineRows().first?.children.map(\.id) == [.task(leaf)])
            t.search = "Missing"
            #expect(t.outlineRows().isEmpty)
            t.search = ""
            let revision = try #require(t.workspace.snapshot?.revision)
            let existing = try #require(t.workspace.snapshot?.projects.first { $0.id == p })
            _ = try await t.workspace.submit(.updateProject(id: p, name: "Renamed", rate: existing.hourlyRate,
                currency: existing.currencyCode, confirmedPreviousCurrency: nil), expectedRevision: revision)
            #expect(t.outlineRows().first?.title == "Renamed")
            _ = try await t.workspace.submit(.setArchived(id: p, archived: true), expectedRevision: revision + 1)
            #expect(t.outlineRows().isEmpty)
            t.showArchived = true
            #expect(t.outlineRows().first?.isArchived == true)
        }
    }

    @Test func revealCompletionOnlyAcceptsCurrentRequestWithoutSheet() async throws {
        try await withTrack { t, _ in
            let p = try await project(t)
            let leaf = try await task(t, project: p)
            t.revealTask(leaf)
            let first = try #require(t.reveal?.id)
            t.editTask(leaf)
            t.completeReveal(requestID: first)
            #expect(t.reveal != nil)
            t.cancelSheet()
            t.completeReveal(requestID: UUID())
            #expect(t.reveal != nil)
            t.completeReveal(requestID: first)
            #expect(t.reveal == nil)
            t.revealTask(leaf)
            t.revealTask(leaf)
            let second = try #require(t.reveal?.id)
            t.completeReveal(requestID: first)
            #expect(t.reveal?.id == second)
        }
    }
}
