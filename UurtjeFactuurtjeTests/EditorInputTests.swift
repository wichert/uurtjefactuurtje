import Foundation
import Testing

@testable import LibraryStore
@testable import UurtjeFactuurtje

@MainActor struct FormInputTests {
  private struct DraftSelection {
    let projectID: UUID
    let leaf: UUID
    let reveal: UUID?
  }

  @Test func projectChecksAreBoundedAndAllowDomainDuplicateNames() async throws {
    try await withTrack { track, _ in
      let projectID = try await project(track)
      track.editProject(projectID)
      guard case .project(var directory) = track.sheet else {
        Issue.record("Missing project")
        return
      }
      let seconds = try #require(track.workspace.snapshot)
      #expect(directory.inputError(in: seconds) == nil)
      directory.reviewedSnapshot = nil
      #expect(directory.inputError(in: seconds) == nil)
      directory.name = " \n\t"
      #expect(directory.inputError(in: seconds) == "Enter a project name.")
      directory.name = "A\0B"
      #expect(
        directory.inputError(in: seconds) == "Remove the null character from the project name.")
      directory.name = "  Project  "
      directory.rateText = "-1"
      #expect(
        directory.inputError(in: seconds)
          == "Enter a nonnegative decimal rate without grouping separators.")
      directory.rateText = "0"
      for bad in ["", "eur", "ZZZ", " EUR "] {
        directory.currencyCode = bad
        #expect(
          directory.inputError(in: seconds)
            == "Enter an uppercase ISO currency code, for example EUR or USD.")
      }
      directory.currencyCode = "USD"
      #expect(directory.inputError(in: seconds) == nil)
      track.cancelSheet()
      track.editProject()
      guard case .project(var new) = track.sheet else {
        Issue.record("Missing new project")
        return
      }
      new.name = "Project"
      #expect(new.inputError(in: seconds) == nil)
      let saved = try await track.workspace.enqueueSubmit(
        .createProject(id: new.id, name: new.name, rate: 0, currency: "EUR"),
        expectedRevision: seconds.revision, reviewedSnapshot: new.reviewedSnapshot
      ).value
      #expect(saved.projects.filter { $0.name == "Project" }.count == 2)
    }
  }

  @Test func siblingKeysExcludeSelfAndUseLatestRecordLocation() async throws {
    try await withTrack { track, _ in
      let projectID = try await project(track)
      let queue = try await project(track, name: "Other")
      let root = try await task(track, project: projectID, name: "Root")
      let own = try await task(track, project: projectID, parent: root, name: "CAFÉ")
      _ = try await task(track, project: projectID, parent: root, name: "Sibling")
      _ = try await task(track, project: queue, name: "Elsewhere")
      track.editTask(own)
      guard case .task(var directory) = track.sheet else {
        Issue.record("Missing task")
        return
      }
      let before = try #require(track.workspace.snapshot)
      verifyEditedSiblingKeys(directory: &directory, before: before, queue: queue)
      track.cancelSheet()
      track.newTask(projectID: projectID, parentID: root)
      guard case .task(var new) = track.sheet else {
        Issue.record("Missing creation draft")
        return
      }
      new.name = "Cafe\u{301}"
      #expect(new.inputError(in: before) != nil)
      new.relocate(projectID: queue, parentID: nil)
      #expect(new.inputError(in: before) == nil)
      new.relocate(projectID: projectID, parentID: root)
      new.name = "Fresh"
      #expect(new.inputError(in: before) == nil)
      _ = try await task(track, project: projectID, parent: root, name: "Fresh")
      let latest = try #require(track.workspace.snapshot)
      #expect(!before.editorRelevantEquals(latest))
      new.reviewedSnapshot = latest
      new.observedRevision = latest.revision
      #expect(
        new.inputError(in: latest)
          == "A task with this name already exists under this parent. Choose a different name.")
      let result = track.workspace.enqueueTaskCreation(
        new.request(start: false), expectedRevision: latest.revision, reviewedSnapshot: latest)
      do {
        _ = try await result.value
        Issue.record("Domain accepted duplicate sibling")
      } catch { #expect(error is LibraryError) }
      #expect(track.workspace.snapshot == latest)
    }
  }

  @Test func realAncestorSaveRestoresDraftWithoutNavigation() async throws {
    try await withTrack { track, _ in
      let projectID = try await project(track)
      let root = try await task(track, project: projectID, name: "Root")
      let leaf = try await task(track, project: projectID, parent: root, name: "Leaf")
      track.revealTask(leaf)
      let reveal = track.reveal?.id
      track.destination = .reports
      track.search = "retained filter"
      track.editTask(leaf)
      guard case .task(var child) = track.sheet else {
        Issue.record("Missing child")
        return
      }
      child.name = "Unsent"
      child.budgetEnabled = true
      child.budgetHours = "17.5"
      child.migrationAccepted = true
      track.updateTaskDraft(child)
      track.editConstrainingBudget(taskID: root)
      guard case .task(let ancestor) = track.sheet else {
        Issue.record("Missing ancestor")
        return
      }
      let token = track.routeToken
      #expect(track.begin(token))
      let saved = try await track.workspace.enqueueSubmit(
        .editTask(id: root, name: "Root edited", budgetMinutes: 100_000),
        expectedRevision: ancestor.observedRevision, reviewedSnapshot: ancestor.reviewedSnapshot
      ).value
      track.complete(token)
      try verifyRestoredDraft(
        track: track, child: child, saved: saved,
        selection: DraftSelection(projectID: projectID, leaf: leaf, reveal: reveal))
    }
  }

  private func verifyEditedSiblingKeys(
    directory: inout TaskDraft, before: LibrarySnapshot, queue: UUID
  ) {
    directory.name = " cafe\u{301} "
    #expect(directory.inputError(in: before) == nil)
    directory.reviewedSnapshot = nil
    #expect(directory.inputError(in: before) == nil)
    directory.name = " sibling "
    directory.projectID = queue
    directory.parentID = nil
    #expect(
      directory.inputError(in: before)
        == "A task with this name already exists under this parent. Choose a different name.")
    directory.name = "Elsewhere"
    #expect(directory.inputError(in: before) == nil)
    directory.name = " \n"
    #expect(directory.inputError(in: before) == "Enter a task name.")
    directory.name = "A\0B"
    #expect(directory.inputError(in: before) == "Remove the null character from the task name.")
  }

  private func verifyRestoredDraft(
    track: TrackPresentation, child: TaskDraft, saved: LibrarySnapshot,
    selection: DraftSelection
  ) throws {
    guard case .task(let restored) = track.sheet else {
      Issue.record("Child not restored")
      return
    }
    #expect(track.suspendedTaskDraft == nil && !track.acceptedWork)
    #expect(restored.id == child.id && restored.name == child.name)
    #expect(
      restored.budgetEnabled == child.budgetEnabled && restored.budgetHours == child.budgetHours)
    #expect(
      restored.originalBudgetMinutes == child.originalBudgetMinutes
        && restored.originalBudgetText == child.originalBudgetText)
    #expect(restored.migrationAccepted == child.migrationAccepted)
    #expect(
      restored.reviewedSnapshot == child.reviewedSnapshot
        && restored.observedRevision == child.observedRevision)
    #expect(
      track.selectedProjectID == selection.projectID && track.selectedTaskID == selection.leaf)
    #expect(
      track.destination == .reports && track.search == "retained filter"
        && track.reveal?.id == selection.reveal)
    let baseline = try #require(restored.reviewedSnapshot)
    #expect(!baseline.editorRelevantEquals(saved))
  }
}
