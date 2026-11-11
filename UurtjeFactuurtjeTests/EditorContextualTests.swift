import Foundation
import Testing

@testable import LibraryStore
@testable import UurtjeFactuurtje

extension ContextualTaskBudgetTests {
  @Test func generatedCacheAndConsentSurviveAncestorCancelAndSaveWithoutRebasing() async throws {
    try await withTrack { track, _ in
      let projectID = try await project(track)
      let root = try await task(track, project: projectID, name: "Root")
      track.newTask(projectID: projectID, parentID: root)
      guard case .task(var directory) = track.sheet else {
        Issue.record("Missing child")
        return
      }
      directory.name = "Unsent child"
      directory.budgetEnabled = true
      // Exactly three minutes in either supported decimal locale.
      directory.budgetHours = "0\(Locale.current.decimalSeparator ?? ".")05"
      directory.stepBudget(by: 30)
      #expect(directory.parsedBudget == 33)
      directory.migrationAccepted = true
      track.updateTaskDraft(directory)
      let original = try #require(directory.reviewedSnapshot)
      for save in [false, true] {
        try await verifyAncestorRoundTrip(
          track: track, directory: directory, original: original, save: save,
          location: (projectID: projectID, root: root))
      }
      let latest = try #require(track.workspace.snapshot)
      #expect(!original.editorRelevantEquals(latest))
      do {
        _ = try await track.workspace.enqueueTaskCreation(
          directory.request(start: false), expectedRevision: directory.observedRevision,
          reviewedSnapshot: directory.reviewedSnapshot
        ).value
        Issue.record("Stale budgeted draft accepted")
      } catch { #expect(track.workspace.snapshot == latest) }
      #expect(track.suspendedTaskDraft == nil && !track.acceptedWork)
    }
  }

  private func verifyAncestorRoundTrip(
    track: TrackPresentation, directory: TaskDraft, original: LibrarySnapshot, save: Bool,
    location: (projectID: UUID, root: UUID)
  ) async throws {
    let projectID = location.projectID
    let root = location.root
    track.editConstrainingBudget(taskID: root)
    #expect(track.suspendedTaskDraft?.generatedBudgetMinutes == 33)
    guard case .task(let ancestor) = track.sheet else {
      Issue.record("Missing ancestor")
      return
    }
    if save {
      let token = track.routeToken
      #expect(track.begin(token))
      _ = try await track.workspace.enqueueSubmit(
        .editTask(id: root, name: ancestor.name, budgetMinutes: 120),
        expectedRevision: ancestor.observedRevision, reviewedSnapshot: ancestor.reviewedSnapshot
      ).value
      track.complete(token)
    } else {
      track.cancelSheet()
    }
    guard case .task(let restored) = track.sheet else {
      Issue.record("Lost child")
      return
    }
    #expect(
      restored.id == directory.id && restored.projectID == projectID
        && restored.parentID == root)
    #expect(restored.name == directory.name && restored.migrationAccepted)
    #expect(restored.budgetHours == directory.budgetHours && restored.parsedBudget == 33)
    #expect(restored.generatedBudgetMinutes == directory.generatedBudgetMinutes)
    #expect(restored.generatedBudgetText == directory.generatedBudgetText)
    #expect(
      restored.reviewedSnapshot == original
        && restored.observedRevision == directory.observedRevision)
  }

  @Test func fixedCreationLocationRejectsUnavailableProjectAndForeignParent() async throws {
    try await withTrack { track, _ in
      let projectID = try await project(track)
      let queue = try await project(track, name: "Other")
      let foreign = try await task(track, project: queue)
      track.newTask(projectID: projectID)
      guard case .task(var directory) = track.sheet else {
        Issue.record("Missing draft")
        return
      }
      directory.name = "New"
      let seconds = try #require(track.workspace.snapshot)
      #expect(directory.inputError(in: seconds) == nil)
      directory.parentID = foreign
      #expect(
        directory.inputError(in: seconds)
          == "This parent is unavailable. Cancel and select a task in this project.")
      directory.parentID = UUID()
      #expect(directory.inputError(in: seconds) != nil)
      directory.parentID = nil
      directory.projectID = UUID()
      #expect(
        directory.inputError(in: seconds)
          == "This project is unavailable for new tasks. Cancel and select an active project.")
      directory.projectID = projectID
      let archived = try await track.workspace.enqueueSubmit(
        .setArchived(id: projectID, archived: true), expectedRevision: seconds.revision
      ).value
      #expect(
        directory.inputError(in: archived)
          == "This project is unavailable for new tasks. Cancel and select an active project.")
    }
  }
}
