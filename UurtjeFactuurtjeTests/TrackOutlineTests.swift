import Foundation
import Testing

@testable import LibraryStore
@testable import UurtjeFactuurtje

@MainActor struct CreationRevealTests {
  @Test(arguments: [false, true])
  func confirmedProjectSelectsEvenWhenEmpty(first: Bool) async throws {
    try await withTrack { track, _ in
      if !first { _ = try await project(track, name: "Existing") }
      track.destination = .reports
      track.search = "hidden"
      track.selectedTaskID = nil
      track.editProject()
      guard case .project(let directory) = track.sheet else {
        Issue.record("Missing project draft")
        return
      }
      let token = track.routeToken
      let before = try #require(track.workspace.snapshot)
      #expect(track.begin(token))
      let accepted = track.workspace.enqueueSubmit(
        .createProject(id: directory.id, name: "Created", rate: 0, currency: "EUR"),
        expectedRevision: directory.observedRevision, reviewedSnapshot: directory.reviewedSnapshot)
      #expect(track.selectedProjectID != directory.id && track.destination == .reports)
      let saved = try await accepted.value
      #expect(track.selectedProjectID != directory.id)
      track.complete(token)
      #expect(saved.revision == before.revision + 1)
      #expect(
        track.destination == .track && track.search.isEmpty
          && track.selectedProjectID == directory.id)
      #expect(track.selectedTaskID == nil && track.rows(projectID: directory.id).isEmpty)
      #expect(saved.activeTimer == nil && !track.acceptedWork)
      if first {
        guard case .task(let next) = track.sheet else {
          Issue.record("Missing first-task onboarding")
          return
        }
        #expect(next.isNew && next.projectID == directory.id && next.reviewedSnapshot == saved)
      } else {
        #expect(track.sheet == nil)
      }
    }
  }

  @Test(arguments: [false, true])
  func createdChildRevealsOnlyAfterCompletionWithoutSecondTimerWrite(start: Bool) async throws {
    try await withTrack { track, _ in
      let projectID = try await project(track)
      let root = try await task(track, project: projectID, name: "Root")
      track.workspace.configureTimer(clock: { 100 })
      track.destination = .reports
      track.search = "hidden"
      track.expandedTaskIDs = []
      track.newTask(projectID: projectID, parentID: root)
      guard case .task(var directory) = track.sheet else {
        Issue.record("Missing task draft")
        return
      }
      directory.name = "Created"
      track.updateTaskDraft(directory)
      let token = track.routeToken
      let before = try #require(track.workspace.snapshot)
      #expect(track.begin(token))
      let accepted = track.workspace.enqueueTaskCreation(
        directory.request(start: start), expectedRevision: directory.observedRevision,
        reviewedSnapshot: directory.reviewedSnapshot)
      #expect(track.reveal == nil && track.selectedTaskID != directory.id)
      let created = try await accepted.value
      #expect(track.reveal == nil && track.destination == .reports)
      track.complete(token)
      #expect(track.sheet == nil && !track.acceptedWork)
      #expect(track.destination == .track && track.search.isEmpty)
      #expect(track.selectedProjectID == projectID && track.selectedTaskID == directory.id)
      #expect(track.expandedTaskIDs.contains(root) && track.reveal?.taskID == directory.id)
      #expect(track.rows(projectID: projectID).contains { $0.id == directory.id })
      #expect(created.snapshot.revision == before.revision + 1)
      #expect(track.workspace.snapshot == created.snapshot)
      #expect(created.snapshot.tasks.first { $0.id == directory.id }?.budgetMinutes == nil)
      if start {
        let active = try #require(created.snapshot.activeTimer)
        #expect(created.snapshot.entries.first { $0.id == active.entryID }?.taskID == directory.id)
        #expect(created.snapshot.entries.first { $0.id == active.entryID }?.startAt == 100)
      } else {
        #expect(created.snapshot.activeTimer == nil && created.snapshot.entries == before.entries)
      }
    }
  }

  @Test func lateCompletionCannotRevealOverReplacementOrConsumeItsAcceptance() async throws {
    try await withTrack { track, _ in
      let projectID = try await project(track)
      track.newTask(projectID: projectID)
      guard case .task(var directory) = track.sheet else {
        Issue.record("Missing task")
        return
      }
      directory.name = "Created"
      track.updateTaskDraft(directory)
      let old = track.routeToken
      #expect(track.begin(old))
      let created = try await track.workspace.enqueueTaskCreation(
        directory.request(start: false), expectedRevision: directory.observedRevision,
        reviewedSnapshot: directory.reviewedSnapshot
      ).value
      track.complete(old)
      let reveal = track.reveal?.id
      track.editProject(projectID)
      let replacement = track.routeToken
      track.destination = .reports
      track.search = "keep"
      #expect(track.begin(replacement))
      track.complete(old)
      #expect(track.routeToken == replacement && track.sheet?.id == projectID && track.acceptedWork)
      #expect(track.destination == .reports && track.search == "keep" && track.reveal?.id == reveal)
      #expect(track.workspace.snapshot == created.snapshot)
      track.complete(replacement, error: EditorError.invalid("Keep draft"))
      #expect(track.sheet?.id == projectID && !track.acceptedWork)
    }
  }

  @Test func failureAndOrdinaryProjectEditDoNotNavigate() async throws {
    try await withTrack { track, _ in
      let projectID = try await project(track)
      let leaf = try await task(track, project: projectID)
      track.revealTask(leaf)
      let reveal = track.reveal?.id
      track.destination = .reports
      track.search = "keep"
      track.editProject(projectID)
      let token = track.routeToken
      let before = try #require(track.workspace.snapshot)
      #expect(track.begin(token))
      track.complete(token, error: EditorError.invalid("disk full"))
      #expect(
        track.sheet?.id == projectID && track.destination == .reports && track.search == "keep")
      #expect(track.reveal?.id == reveal && track.workspace.snapshot == before)
      #expect(track.begin(token))
      let saved = try await track.workspace.enqueueSubmit(
        .updateProject(
          id: projectID, name: "Edited", rate: 75, currency: "EUR", confirmedPreviousCurrency: nil),
        expectedRevision: before.revision, reviewedSnapshot: before
      ).value
      track.complete(token)
      #expect(track.sheet == nil && !track.acceptedWork)
      #expect(track.destination == .reports && track.search == "keep" && track.reveal?.id == reveal)
      #expect(
        track.selectedProjectID == projectID && track.selectedTaskID == leaf
          && track.workspace.snapshot == saved)
    }
  }
}

@Suite @MainActor struct RevealConsumptionTests {
  @Test func consumedRevealIsNotReplayedByOrdinaryEdit() async throws {
    try await withTrack { track, _ in
      let projectID = try await project(track)
      let leaf = try await task(track, project: projectID)
      track.revealTask(leaf)
      let route = track.routeToken
      let request = try #require(track.reveal)
      #expect(request.taskID == leaf)
      track.completeReveal(requestID: request.id)
      #expect(track.routeToken == route && track.sheet == nil)
      track.completeReveal(requestID: request.id)
      #expect(track.reveal == nil)
      track.editTask(leaf)
      let token = track.routeToken
      let before = try #require(track.workspace.snapshot)
      #expect(track.begin(token))
      _ = try await track.workspace.enqueueSubmit(
        .editTask(id: leaf, name: "Edited", budgetMinutes: nil),
        expectedRevision: before.revision, reviewedSnapshot: before
      ).value
      track.complete(token)
      track.completeReveal(requestID: request.id)
      #expect(track.sheet == nil && track.reveal == nil)
      #expect(track.selectedTaskID == leaf)
    }
  }

  @Test func revealRequestedDuringSheetIsDeferredThenTakenOnce() async throws {
    try await withTrack { track, _ in
      let projectID = try await project(track)
      let leaf = try await task(track, project: projectID)
      track.editTask(leaf)
      track.revealTask(leaf)
      let route = track.routeToken
      let request = try #require(track.reveal)
      track.completeReveal(requestID: request.id)
      #expect(track.reveal?.id == request.id)
      #expect(track.routeToken == route && track.sheet?.id == leaf)
      track.cancelSheet()
      let dismissedRoute = track.routeToken
      #expect(track.reveal?.id == request.id && track.reveal?.taskID == leaf)
      track.completeReveal(requestID: request.id)
      #expect(track.routeToken == dismissedRoute && track.sheet == nil)
      track.completeReveal(requestID: request.id)
      #expect(track.reveal == nil)
    }
  }

  @Test func createdTaskRevealSurvivesCreationAndDiesBeforeOrdinaryEdit() async throws {
    try await withTrack { track, _ in
      let projectID = try await project(track)
      let root = try await task(track, project: projectID, name: "Root")
      track.destination = .reports
      track.search = "hidden"
      track.newTask(projectID: projectID, parentID: root)
      guard case .task(var directory) = track.sheet else {
        Issue.record("Missing task draft")
        return
      }
      directory.name = "Created"
      track.updateTaskDraft(directory)
      let token = track.routeToken
      #expect(track.begin(token))
      let created = try await track.workspace.enqueueTaskCreation(
        directory.request(start: false),
        expectedRevision: directory.observedRevision, reviewedSnapshot: directory.reviewedSnapshot
      ).value
      track.complete(token)
      #expect(
        track.destination == .track && track.search.isEmpty && track.selectedTaskID == directory.id)
      let request = try #require(track.reveal)
      #expect(request.taskID == directory.id)
      track.completeReveal(requestID: request.id)
      #expect(track.reveal == nil && track.workspace.snapshot == created.snapshot)
      track.editTask(directory.id)
      let edit = track.routeToken
      let before = try #require(track.workspace.snapshot)
      #expect(track.begin(edit))
      _ = try await track.workspace.enqueueSubmit(
        .editTask(id: directory.id, name: "Renamed", budgetMinutes: nil),
        expectedRevision: before.revision, reviewedSnapshot: before
      ).value
      track.complete(edit)
      track.completeReveal(requestID: request.id)
      #expect(track.sheet == nil && track.reveal == nil)
      #expect(track.workspace.snapshot?.tasks.first { $0.id == directory.id }?.name == "Renamed")
    }
  }
}
