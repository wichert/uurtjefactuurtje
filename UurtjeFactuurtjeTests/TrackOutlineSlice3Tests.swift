import Foundation
import Testing

@testable import LibraryStore
@testable import UurtjeFactuurtje

@MainActor struct TrackOutlineSlice3Tests {
    @Test func rowIdentitySelectionAndLegacyWritesStayCoherent() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track, name: "A")
            let queue = try await project(track, name: "B")
            let leaf = try await task(track, project: projectID)
            track.selectedRow = .task(leaf)
            #expect(track.selectedTaskID == leaf && track.selectedProjectID == projectID)
            track.selectedProjectID = projectID
            #expect(track.selectedRow == .task(leaf))
            track.selectedProjectID = queue
            #expect(track.selectedRow == .project(queue) && track.selectedTaskID == nil)
            track.selectedTaskID = leaf
            #expect(track.selectedRow == .task(leaf) && track.selectedProjectID == projectID)
            track.selectedTaskID = nil
            #expect(track.selectedRow == .project(projectID))
            track.selectedRow = .task(UUID())
            #expect(track.selectedRow == .project(projectID))
            track.selectedProjectID = nil
            #expect(track.selectedRow == nil && track.selectedTaskID == nil)
            track.selectedTaskID = UUID()
            track.expandedProjectIDs = [projectID, UUID()]
            track.reconcile()
            #expect(track.selectedRow == nil)
            #expect(track.expandedProjectIDs == [projectID])
            #expect(TrackRowID.project(projectID) != TrackRowID.task(projectID))
        }
    }

    @Test func nestedSearchKeepsAncestorsStructuralLeavesAndExpansion() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track, name: "Client")
            let root = try await task(track, project: projectID, name: "Parent")
            let match = try await task(track, project: projectID, parent: root, name: "Needle")
            _ = try await task(track, project: projectID, parent: root, name: "Other")
            let empty = try await project(track, name: "Empty")
            let outline = track.outlineRows()
            let parent = try #require(outline.first { $0.id == .project(projectID) }?.children.first)
            #expect(parent.id == .task(root) && !parent.isLeafTask && parent.children.count == 2)
            #expect(parent.path == "Client / Parent" && !parent.isArchived)
            #expect(outline.first { $0.id == .project(empty) }?.isLeafTask == false)
            track.selectedRow = .task(match)
            #expect(!track.isVisible(.task(match)))
            #expect(!track.canStartFromList(match, listFocused: true))
            track.search = "Needle"
            let filtered = track.outlineRows()
            let projectRow = try #require(filtered.first)
            let rootRow = try #require(projectRow.children.first)
            #expect(filtered.count == 1 && projectRow.id == .project(projectID))
            #expect(rootRow.id == .task(root) && !rootRow.isLeafTask)
            #expect(rootRow.children.map(\.id) == [.task(match)])
            #expect(rootRow.children.first?.isLeafTask == true)
            #expect(track.isVisible(.task(match)))
            #expect(track.canStartFromList(match, listFocused: true))
            #expect(!track.canStartFromList(match, listFocused: false))
            #expect(track.expandedProjectIDs.isEmpty && track.expandedTaskIDs.isEmpty)
            track.search = "Empty"
            #expect(track.outlineRows().map(\.id) == [.project(empty)])
            track.search = "Client"
            #expect(track.outlineRows().first?.children.contains { $0.id == .task(root) } == true)
            track.search = ""
            #expect(!track.isVisible(.task(match)))
            #expect(track.selectedRow == .task(match))
            track.expandedProjectIDs.insert(projectID)
            #expect(track.isVisible(.task(root)) && !track.isVisible(.task(match)))
            track.expandedTaskIDs.insert(root)
            #expect(track.isVisible(.task(match)))
        }
    }

    @Test func expansionPersistsAndArchivedRevealRemainsSheetDeferred() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let root = try await task(track, project: projectID, name: "Root")
            let leaf = try await task(track, project: projectID, parent: root, name: "Leaf")
            let before = try #require(track.workspace.snapshot)
            _ = try await track.workspace.submit(
                .setArchived(id: projectID, archived: true), expectedRevision: before.revision)
            track.selectedRow = .task(leaf)
            track.reconcile()
            #expect(track.outlineRows().isEmpty && track.selectedRow == .task(leaf))
            #expect(!track.eligible(leaf))
            track.editTask(leaf)
            let token = track.routeToken
            track.revealTask(leaf)
            let first = try #require(track.reveal?.id)
            track.revealTask(leaf)
            #expect(track.reveal?.id != first && track.routeToken == token)
            let current = try #require(track.reveal?.id)
            track.completeReveal(requestID: first)
            #expect(track.reveal?.id == current)
            #expect(
                track.showArchived && track.expandedProjectIDs.contains(projectID)
                    && track.expandedTaskIDs.contains(root))
            #expect(track.isVisible(.task(leaf)) && track.reveal != nil)
            let row = try #require(track.outlineRows().first)
            #expect(row.isArchived && row.children.first?.children.first?.isArchived == true)
            track.cancelSheet()
            #expect(track.reveal?.taskID == leaf && track.reveal != nil)
            track.revealTask(leaf)
            let mounted = try #require(track.reveal?.id)
            track.completeReveal(requestID: mounted)
            #expect(track.reveal == nil)

            let suite = "TrackSlice3.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(UUID().uuidString, forKey: "track.project")
            defaults.set(leaf.uuidString, forKey: "track.task")
            let restored = TrackPresentation(workspace: track.workspace, defaults: defaults)
            restored.reconcile()
            #expect(restored.selectedRow == .task(leaf) && restored.selectedProjectID == projectID)
            restored.expandedProjectIDs = [projectID]
            restored.expandedTaskIDs = [root]
            restored.search = "Leaf"
            _ = restored.outlineRows()
            let second = TrackPresentation(workspace: track.workspace, defaults: defaults)
            #expect(second.expandedProjectIDs == [projectID] && second.expandedTaskIDs == [root])
            #expect(second.selectedRow == .task(leaf) && second.selectedProjectID == projectID)
        }
    }

    @Test func closedAndLiveRollUpOnceAndCheckpointSurvivesRollbackAndSleep() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let root = try await task(track, project: projectID, name: "Root")
            let leaf = try await task(track, project: projectID, parent: root, name: "Leaf")
            let empty = try await project(track, name: "Empty")
            track.workspace.configureTimer(clock: { 100 })
            _ = try await track.workspace.enqueueTimer(.start(taskID: leaf)).value
            track.workspace.configureTimer(clock: { 160 })
            let first = try #require(track.workspace.snapshot?.activeTimer)
            _ = try await track.workspace.enqueueTimer(.stop(expectedEntryID: first.entryID)).value
            track.workspace.configureTimer(clock: { 200 })
            _ = try await track.workspace.enqueueTimer(.start(taskID: leaf)).value
            track.workspace.configureTimer(clock: { 230 })
            _ = try await track.workspace.enqueueTimer(.checkpoint).value
            track.workspace.configureTimer(clock: { 260 })
            let before = try #require(track.workspace.snapshot)
            let warnings = track.workspace.budgetWarnings.map(\.id)
            let totals = try track.projectTaskTotals()
            #expect(totals[.task(leaf)] == 120 && totals[.task(root)] == 120)
            #expect(totals[.project(projectID)] == 120 && totals[.project(empty)] == 0)
            track.search = "hidden"
            #expect(try track.projectTaskTotals() == totals)
            #expect(
                track.workspace.snapshot == before && track.workspace.budgetWarnings.map(\.id) == warnings)
            track.workspace.configureTimer(clock: { 220 })
            #expect(try track.workspace.trackLiveEnd() == nil)
            #expect(try track.projectTaskTotals()[.project(projectID)] == 90)
            track.workspace.configureTimer(clock: { 300 })
            _ = track.workspace.timerLifecycleGate.latchSleep()
            #expect(try track.workspace.trackLiveEnd() == nil)
            #expect(try track.projectTaskTotals()[.task(leaf)] == 90)
            #expect(track.workspace.snapshot == before)
        }
    }

    @Test func wakePendingIsExcludedAndRestoredActiveUsesCheckpoint() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let leaf = try await task(track, project: projectID)
            track.workspace.configureTimer(clock: { 100 })
            _ = try await track.workspace.enqueueTimer(.start(taskID: leaf)).value
            track.workspace.configureTimer(clock: { 150 })
            let generation = track.workspace.timerLifecycleGate.latchSleep()
            await track.workspace.enqueueSleepObservation(generation: generation).value
            #expect(track.workspace.snapshot?.pendingSleepIntervals.count == 1)
            #expect(try track.projectTaskTotals()[.project(projectID)] == 50)
            track.workspace.configureTimer(clock: { 300 })
            await track.workspace.enqueueWakeObservation(generation: generation, observedAt: 300).value
            track.workspace.configureTimer(clock: { 330 })
            _ = try await track.workspace.enqueueTimer(.checkpoint).value
            track.workspace.configureTimer(clock: { 350 })
            #expect(try track.projectTaskTotals()[.project(projectID)] == 100)
            #expect(track.workspace.snapshot?.pendingSleepIntervals.first?.wakeAt == 300)
            await track.workspace.close()
            try await track.workspace.open()
            #expect(track.workspace.timerStatus == .reviewRequired)
            #expect(try track.workspace.trackLiveEnd() == nil)
            #expect(try track.projectTaskTotals()[.project(projectID)] == 80)
        }
    }

    @Test func checkedDurationAndAllRollupLevelsFailWithoutWrapping() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let root = try await task(track, project: projectID, name: "Root")
            let first = try await task(track, project: projectID, parent: root, name: "A")
            let second = try await task(track, project: projectID, parent: root, name: "B")
            let base = try #require(track.workspace.snapshot)
            func snapshot(tasks: [TaskRecord], entries: [TimeEntry], active: ActiveTimer? = nil)
                -> LibrarySnapshot {
                LibrarySnapshot(
                    schemaVersion: 2, revision: base.revision, projects: base.projects,
                    tasks: tasks, entries: entries, activeTimer: active, pendingSleepIntervals: [])
            }
            let huge = TimeEntry(id: UUID(), taskID: first, startAt: 0, endAt: Int64.max)
            let one = TimeEntry(id: UUID(), taskID: second, startAt: 0, endAt: 1)
            let parentOverflow = snapshot(tasks: base.tasks, entries: [huge, one])
            #expect(throws: ReportError.intervalOverflow) {
                try TrackPresentation.projectTaskTotals(in: parentOverflow, liveEnd: nil)
            }
            let sameLeaf = TimeEntry(id: UUID(), taskID: first, startAt: 0, endAt: 1)
            #expect(throws: ReportError.intervalOverflow) {
                try TrackPresentation.projectTaskTotals(
                    in: snapshot(tasks: base.tasks, entries: [huge, sameLeaf]), liveEnd: nil)
            }
            let roots = [
                TaskRecord(id: first, projectID: projectID, name: "A"),
                TaskRecord(id: second, projectID: projectID, name: "B")
            ]
            #expect(throws: ReportError.intervalOverflow) {
                try TrackPresentation.projectTaskTotals(
                    in: snapshot(tasks: roots, entries: [huge, one]), liveEnd: nil)
            }
            let bad = TimeEntry(id: UUID(), taskID: first, startAt: Int64.min, endAt: Int64.max)
            #expect(throws: ReportError.intervalOverflow) {
                try TrackPresentation.projectTaskTotals(
                    in: snapshot(tasks: roots, entries: [bad]), liveEnd: nil)
            }
            let open = TimeEntry(id: UUID(), taskID: first, startAt: 10, endAt: nil)
            let active = ActiveTimer(entryID: open.id, checkpointAt: 10)
            let zero = snapshot(tasks: roots, entries: [open], active: active)
            #expect(try TrackPresentation.projectTaskTotals(in: zero, liveEnd: nil)[.task(first)] == 0)
            #expect(throws: ReportError.invalidActiveEntry) {
                try TrackPresentation.projectTaskTotals(in: zero, liveEnd: 9)
            }
        }
    }
}

extension TrackOutlineSlice3Tests {
    @Test func hiddenOrCollapsedSelectionDoesNotEnableContextualCreation() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let leaf = try await task(track, project: projectID)
            track.selectedTaskID = leaf
            #expect(track.selectedRow.map { track.isVisible($0) } == false)
            track.expandedProjectIDs = [projectID]
            #expect(track.selectedRow.map { track.isVisible($0) } == true)
            track.search = "No match"
            #expect(track.selectedRow.map { track.isVisible($0) } == false)
            track.search = ""
            #expect(track.selectedRow.map { track.isVisible($0) } == true)
        }
    }
}

extension TrackOutlineSlice3Tests {
    @Test func collapsedProjectAndTaskBothGuardKeyboardStart() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track, name: "Project")
            var parent = try await task(track, project: projectID, name: "Task 0")
            for index in 1..<34 {
                parent = try await task(track, project: projectID, parent: parent, name: "Task \(index)")
            }
            track.selectedTaskID = parent
            #expect(!track.canStartFromList(parent, listFocused: true))
            track.expandedProjectIDs = [projectID]
            #expect(!track.isVisible(.task(parent)))
            #expect(!track.canStartFromList(parent, listFocused: true))
            var row = track.outlineRows().first?.children.first
            var prefix: [UUID] = []
            while let current = row, current.id != .task(parent) {
                guard case .task(let id) = current.id else { break }
                prefix.append(id)
                row = current.children.first
            }
            #expect(prefix.count == 33)
            track.expandedTaskIDs = Set(prefix)
            #expect(track.isVisible(.task(parent)))
            #expect(track.canStartFromList(parent, listFocused: true))
            #expect(!track.canStartFromList(parent, listFocused: false))
            track.expandedTaskIDs = Set(prefix.dropLast())
            #expect(!track.isVisible(.task(parent)))
            #expect(!track.canStartFromList(parent, listFocused: true))
        }
    }

    @Test func outlineCacheSurvivesExpansionAndInvalidatesQueryArchiveAndRevision() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track, name: "Client")
            let leaf = try await task(track, project: projectID, name: "Alpha")
            let first = track.outlineRows()
            track.expandedProjectIDs = [projectID]
            track.expandedTaskIDs = [leaf]
            let cached = track.outlineRows()
            #expect(cached.count == first.count && cached[0].path == first[0].path)
            #expect(cached[0].children.map(\.id) == first[0].children.map(\.id))
            track.search = "Alpha"
            #expect(track.outlineRows().first?.children.map(\.id) == [.task(leaf)])
            track.search = "Missing"
            #expect(track.outlineRows().isEmpty)
            track.search = ""
            let revision = try #require(track.workspace.snapshot?.revision)
            let existing = try #require(track.workspace.snapshot?.projects.first { $0.id == projectID })
            _ = try await track.workspace.submit(
                .updateProject(
                    id: projectID, name: "Renamed", rate: existing.hourlyRate,
                    currency: existing.currencyCode, confirmedPreviousCurrency: nil),
                expectedRevision: revision)
            #expect(track.outlineRows().first?.title == "Renamed")
            _ = try await track.workspace.submit(
                .setArchived(id: projectID, archived: true), expectedRevision: revision + 1)
            #expect(track.outlineRows().isEmpty)
            track.showArchived = true
            #expect(track.outlineRows().first?.isArchived == true)
        }
    }

    @Test func revealCompletionOnlyAcceptsCurrentRequestWithoutSheet() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let leaf = try await task(track, project: projectID)
            track.revealTask(leaf)
            let first = try #require(track.reveal?.id)
            track.editTask(leaf)
            track.completeReveal(requestID: first)
            #expect(track.reveal != nil)
            track.cancelSheet()
            track.completeReveal(requestID: UUID())
            #expect(track.reveal != nil)
            track.completeReveal(requestID: first)
            #expect(track.reveal == nil)
            track.revealTask(leaf)
            track.revealTask(leaf)
            let second = try #require(track.reveal?.id)
            track.completeReveal(requestID: first)
            #expect(track.reveal?.id == second)
        }
    }
}
