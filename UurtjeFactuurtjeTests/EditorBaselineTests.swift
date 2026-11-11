import Foundation
import Testing

@testable import LibraryStore
@testable import UurtjeFactuurtje

@MainActor struct EditorBaselineTests {
  @Test func legacyDraftMemberwiseInitializersRemainCompatible() {
    let projectID = ProjectDraft(
      id: UUID(), isNew: true, observedRevision: 4,
      name: "Draft", rateText: "0", currencyCode: "EUR",
      confirmedPreviousCurrency: nil, archiveConfirmed: false)
    let track = TaskDraft(
      id: UUID(), isNew: true, observedRevision: 4,
      projectID: UUID(), parentID: nil, name: "Draft", migrationAccepted: false,
      budgetEnabled: false, budgetHours: "", originalBudgetMinutes: nil, originalBudgetText: "")
    #expect(projectID.reviewedSnapshot == nil)
    #expect(track.reviewedSnapshot == nil)
    #expect(projectID.observedRevision == 4 && track.observedRevision == 4)
  }

  @Test func everyDraftFactoryCapturesConfirmedSnapshot() async throws {
    try await withTrack { track, _ in
      let empty = try #require(track.workspace.snapshot)
      track.editProject()
      guard case .project(let first) = track.sheet else {
        Issue.record("Missing new project")
        return
      }
      #expect(first.reviewedSnapshot == empty && first.observedRevision == empty.revision)
      track.cancelSheet()
      let projectID = try await project(track)
      let root = try await task(track, project: projectID, name: "Root")
      let leaf = try await task(track, project: projectID, parent: root, name: "Leaf")
      let current = try #require(track.workspace.snapshot)
      track.editProject(projectID)
      guard case .project(let projectDraft) = track.sheet else {
        Issue.record("Missing project edit")
        return
      }
      #expect(
        projectDraft.reviewedSnapshot == current
          && projectDraft.observedRevision == current.revision)
      track.cancelSheet()
      track.newTask(projectID: projectID, parentID: root)
      guard case .task(let newDraft) = track.sheet else {
        Issue.record("Missing new task")
        return
      }
      #expect(newDraft.reviewedSnapshot == current && newDraft.observedRevision == current.revision)
      track.cancelSheet()
      track.editTask(leaf)
      guard case .task(let edited) = track.sheet else {
        Issue.record("Missing task edit")
        return
      }
      #expect(edited.reviewedSnapshot == current && edited.observedRevision == current.revision)
      track.editConstrainingBudget(taskID: root)
      guard case .task(let ancestor) = track.sheet else {
        Issue.record("Missing ancestor edit")
        return
      }
      #expect(ancestor.id == root && ancestor.reviewedSnapshot == current)
      #expect(ancestor.observedRevision == current.revision)
      #expect(track.suspendedTaskDraft?.reviewedSnapshot == current)
    }
  }

  @Test func checkpointDoesNotRebaseOpenDraftsOrConsumeConsent() async throws {
    try await withTrack { track, _ in
      let projectID = try await project(track)
      let leaf = try await task(track, project: projectID)
      track.workspace.configureTimer(clock: { 100 })
      let running = try await track.workspace.enqueueTimer(.start(taskID: leaf)).value
      track.newTask(projectID: projectID, parentID: leaf)
      guard case .task(var draft) = track.sheet else {
        Issue.record("Missing task draft")
        return
      }
      draft.name = "Unsent"
      draft.migrationAccepted = true
      track.updateTaskDraft(draft)
      track.workspace.configureTimer(clock: { 120 })
      let tick = try await track.workspace.enqueueTimer(.checkpoint).value
      guard case .task(let retained) = track.sheet else {
        Issue.record("Lost task draft")
        return
      }
      #expect(retained.reviewedSnapshot == running)
      #expect(retained.observedRevision == running.revision)
      #expect(retained.migrationAccepted && retained.name == "Unsent")
      let taskBaseline = try #require(retained.reviewedSnapshot)
      #expect(taskBaseline.editorRelevantEquals(tick))
      track.cancelSheet()
      track.editProject(projectID)
      guard case .project(let projectDraft) = track.sheet else {
        Issue.record("Missing project draft")
        return
      }
      track.workspace.configureTimer(clock: { 140 })
      let next = try await track.workspace.enqueueTimer(.checkpoint).value
      guard case .project(let retainedProject) = track.sheet else {
        Issue.record("Lost project draft")
        return
      }
      #expect(retainedProject.reviewedSnapshot == projectDraft.reviewedSnapshot)
      let projectBaseline = try #require(retainedProject.reviewedSnapshot)
      #expect(projectBaseline.editorRelevantEquals(next))
      #expect(retainedProject.observedRevision == tick.revision)
    }
  }

  @Test func suspendedDraftPreservesBaselineOnCancelAndRealAncestorSave() async throws {
    try await withTrack { track, _ in
      let projectID = try await project(track)
      let root = try await task(track, project: projectID, name: "Root")
      let leaf = try await task(track, project: projectID, parent: root, name: "Leaf")
      track.editTask(leaf)
      guard case .task(var draft) = track.sheet else {
        Issue.record("Missing child")
        return
      }
      let original = try #require(draft.reviewedSnapshot)
      draft.name = "Unsent name"
      draft.budgetEnabled = true
      draft.budgetHours = "17.5"
      draft.migrationAccepted = true
      track.updateTaskDraft(draft)
      let renamed = try await track.workspace.submit(
        .renameTask(id: root, name: "Changed root"),
        expectedRevision: original.revision)
      track.editConstrainingBudget(taskID: root)
      guard case .task(let ancestor) = track.sheet else {
        Issue.record("Missing ancestor")
        return
      }
      verifySuspendedDraft(
        ancestor, renamed: renamed, suspended: track.suspendedTaskDraft, original: original)
      track.cancelSheet()
      try verifyCancelledDraft(track: track, original: original)
      track.editConstrainingBudget(taskID: root)
      let token = track.routeToken
      guard case .task(let savingAncestor) = track.sheet else {
        Issue.record("Missing second ancestor")
        return
      }
      #expect(track.begin(token))
      let saved = try await track.workspace.enqueueSubmit(
        .editTask(id: root, name: savingAncestor.name, budgetMinutes: 100_000),
        expectedRevision: savingAncestor.observedRevision,
        reviewedSnapshot: savingAncestor.reviewedSnapshot
      ).value
      track.complete(token)
      try verifySavedDraft(track: track, original: original, saved: saved)
    }
  }

  private func verifySavedDraft(
    track: TrackPresentation, original: LibrarySnapshot, saved: LibrarySnapshot
  ) throws {
    guard case .task(let restored) = track.sheet else {
      Issue.record("Missing child after save")
      return
    }
    #expect(track.suspendedTaskDraft == nil)
    #expect(restored.reviewedSnapshot == original && restored.observedRevision == original.revision)
    #expect(
      restored.name == "Unsent name" && restored.budgetHours == "17.5" && restored.budgetEnabled)
    #expect(restored.migrationAccepted)
    #expect(!original.editorRelevantEquals(saved))
    #expect(!track.acceptedWork)
  }

  private func verifySuspendedDraft(
    _ ancestor: TaskDraft, renamed: LibrarySnapshot, suspended: TaskDraft?,
    original: LibrarySnapshot
  ) {
    #expect(ancestor.reviewedSnapshot == renamed && ancestor.observedRevision == renamed.revision)
    #expect(suspended?.reviewedSnapshot == original)
  }

  private func verifyCancelledDraft(track: TrackPresentation, original: LibrarySnapshot) throws {
    guard case .task(let canceled) = track.sheet else {
      Issue.record("Missing restored child")
      return
    }
    #expect(canceled.reviewedSnapshot == original && canceled.observedRevision == original.revision)
    #expect(
      canceled.name == "Unsent name" && canceled.budgetHours == "17.5" && canceled.budgetEnabled)
    #expect(canceled.migrationAccepted)
  }
}
