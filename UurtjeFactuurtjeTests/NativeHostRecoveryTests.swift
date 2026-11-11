import AppKit
import Foundation
import SwiftUI
import Testing
import UserNotifications

@testable import LibraryStore
@testable import UurtjeFactuurtje

actor NativeRecoveryProbe {
  private var openError: (any Error)?
  private var writeError: (any Error)?
  private var snapshotError: LibraryAccessError?
  private var opens = 0
  private var writes = 0

  init(openError: (any Error)? = nil) { self.openError = openError }
  func setOpenError(_ error: (any Error)?) { openError = error }
  func setFailWrite(_ error: any Error = LibraryAccessError.publicationIndeterminate) {
    writeError = error
  }
  func setFailSnapshot(_ fail: Bool, error: LibraryAccessError = .unavailable) {
    snapshotError = fail ? error : nil
  }
  func snapshot(_ library: Library) async throws -> LibrarySnapshot {
    if let snapshotError { throw snapshotError }
    return try await library.snapshot()
  }
  func counts() -> (opens: Int, writes: Int) { (opens, writes) }
  func open(_ directory: URL) async throws -> Library {
    opens += 1
    if let openError { throw openError }
    return try await Library.open(at: directory)
  }
  func perform(_ library: Library, _ command: WorkspaceCommand, _ revision: Int64) async throws
    -> LibrarySnapshot {
    writes += 1
    if let writeError { throw writeError }
    return try await library.perform(command, expectedRevision: revision)
  }
}

extension NativeHostTests {
  @Test func recoveryMessagesClassifyTypedIssuesWithoutDurabilityClaims() {
    let cases: [(WorkspaceIssue, String)] = [
      (.busy, "Another app or process"),
      (.unsafeLibrary, "could not be opened safely"),
      (.invalidStorage, "unsupported format"),
      (.revisionConflict, "library changed"),
      (.recoveryRequired, "Time needs review"),
      (.uncertainSave, "may or may not have been saved"),
      (.command(.missingRecord), "action could not be completed"),
      (.validation([Violation(.interval)]), "data that could not be accepted"),
      (.unavailable, "library is unavailable"),
      (.closed, "library is unavailable"),
      (.other("raw diagnostic sentinel"), "action could not be completed")
    ]
    for (issue, phrase) in cases {
      let message = RecoveryMessage.text(issue: issue, availability: .blocked)
      #expect(message.contains(phrase))
      #expect(!message.contains("raw diagnostic sentinel"))
    }
    let uncertain = RecoveryMessage.text(issue: .uncertainSave, availability: .blocked)
    #expect(uncertain.contains("Do not repeat it"))
    #expect(uncertain.contains("or assume it is safe to discard"))
    #expect(!uncertain.contains("successfully saved"))
    #expect(
      RecoveryMessage.text(issue: .validation([Violation(.task)]), availability: .ready)
        .contains("affected fields"))
    #expect(RecoveryMessage.text(issue: nil, availability: .opening).contains("Opening"))
    #expect(RecoveryMessage.text(issue: .busy, availability: .opening).contains("Opening"))
    #expect(RecoveryMessage.text(issue: nil, availability: .closing).contains("Closing"))
    #expect(RecoveryMessage.text(issue: nil, availability: .closed).contains("closed"))
    #expect(RecoveryMessage.text(issue: nil, availability: .blocked).contains("blocked"))
    #expect(
      RecoveryMessage.text(issue: nil, availability: .reviewRequired).contains("unbilled"))
    let stale = RecoveryMessage.text(issue: .revisionConflict, availability: .blocked)
    #expect(stale.contains("Retained rows may be stale"))
    #expect(stale.contains("reopen and inspect"))
    #expect(!stale.contains("current rows"))
  }

  @Test func openFailuresUseActualDirectoryAndKeepDiagnosticsSeparate() async throws {
    let failures: [(any Error, WorkspaceIssue)] = [
      (LibraryOpenError.busy, .busy),
      (LibraryOpenError.unsafeState("unsafe sentinel"), .unsafeLibrary),
      (StorageError.invalidStorage("invalid sentinel"), .invalidStorage),
      (StorageError.unsupportedSchema(999), .invalidStorage),
      (LibraryError.invalid([Violation(.interval)]), .validation([Violation(.interval)])),
      (
        LibraryOpenError.filesystem("filesystem sentinel", 13),
        .other(String(describing: LibraryOpenError.filesystem("filesystem sentinel", 13)))
      )
    ]
    for (error, expected) in failures {
      let directory = fixtureTemporaryDirectory().appendingPathComponent(
        "RecoveryActual.\(UUID())", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let suite = "NativeRecovery.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let probe = NativeRecoveryProbe(openError: error)
      var operations = WorkspaceOperations()
      operations.open = { try await probe.open($0) }
      let workspace = WorkspaceModel(directory: directory, operations: operations)
      let host = NativeHost(directory: directory, workspace: workspace, defaults: defaults)
      defer { host.invalidate() }
      #expect(host.canReopen)
      _ = WorkspaceView(host: host) { Text("Reports") }
      host.reopen()
      #expect(workspace.availability == .opening)
      #expect(!host.canReopen)
      host.reopen()  // Opening is not another accepted open.
      await host.drain()
      #expect(workspace.issue == expected)
      #expect(workspace.availability == .blocked)
      #expect(workspace.snapshot == nil)
      #expect(host.directory == directory)
      #expect(host.recoveryDiagnostics.contains("Library: \(directory.path)"))
      #expect(host.recoveryDiagnostics.contains("No confirmed snapshot"))
      #expect(host.recoveryDiagnostics.contains("Workspace issue:"))
      #expect(!host.recoveryMessage.contains("sentinel"))
      #expect(host.canReopen)  // A completed lock-busy failure is retryable, not in-flight work.
      #expect(!workspace.isBusy && host.hasRecoveryFeedback)
      try await verifyOpenFailureDiagnostics(host: host, workspace: workspace, probe: probe)
    }
  }

  @Test func uncertainWriteAndFailedReopenKeepConfirmedRowsAndNeverReplay() async throws {
    let directory = fixtureTemporaryDirectory().appendingPathComponent(
      "RecoveryActual.\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "NativeRecovery.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let probe = NativeRecoveryProbe()
    var operations = WorkspaceOperations()
    operations.open = { try await probe.open($0) }
    operations.perform = { try await probe.perform($0, $1, $2) }
    let workspace = WorkspaceModel(directory: directory, operations: operations)
    let host = NativeHost(directory: directory, workspace: workspace, defaults: defaults)
    defer { host.invalidate() }
    host.reopen()
    await host.drain()
    #expect(host.available && !host.canReopen)
    let initial = try #require(workspace.snapshot)
    _ = try await workspace.submit(
      .createProject(id: UUID(), name: "Confirmed", rate: 100, currency: "EUR"),
      expectedRevision: initial.revision)
    let before = try #require(workspace.snapshot)
    await probe.setFailWrite()
    do {
      _ = try await workspace.submit(
        .createProject(id: UUID(), name: "Uncertain", rate: 100, currency: "EUR"),
        expectedRevision: before.revision)
      Issue.record("Expected uncertain publication")
    } catch {
      #expect((error as? LibraryAccessError) == .publicationIndeterminate)
    }
    verifyUncertainPublication(host: host, workspace: workspace, before: before)
    try await verifyFailedReopenDoesNotReplay(
      host: host, workspace: workspace, probe: probe, before: before)
    await probe.setOpenError(nil)
    host.track.failure = "Unsent draft error sentinel"
    host.reopen()
    #expect(host.hasUncertainPublication && host.recoveryMessage.contains("Do not repeat it"))
    await host.drain()
    verifyHealthyUncertainReopen(host: host, workspace: workspace)
    host.track.failure = nil  // Test-only cleanup; production reopen must not clear another error.
    #expect(!host.hasRecoveryFeedback)
    #expect(workspace.snapshot == before)
    try await verifyHealthyWorkspaceCannotReopen(host: host, workspace: workspace, probe: probe)
  }

  private func verifyUncertainPublication(
    host: NativeHost, workspace: WorkspaceModel, before: LibrarySnapshot
  ) {
    #expect(workspace.issue == .uncertainSave && workspace.availability == .blocked)
    #expect(workspace.snapshot == before)
    #expect(host.recoveryDiagnostics.contains("Last confirmed revision: \(before.revision)"))
    #expect(host.recoveryMessage.contains("may or may not"))
    #expect(workspace.publicationUncertain && host.hasUncertainPublication)
  }

  private func verifyFailedReopenDoesNotReplay(
    host: NativeHost, workspace: WorkspaceModel, probe: NativeRecoveryProbe,
    before: LibrarySnapshot
  ) async throws {
    var counts = await probe.counts()
    #expect(counts.opens == 1 && counts.writes == 2)
    await probe.setOpenError(LibraryOpenError.busy)
    host.reopen()
    #expect(workspace.availability == .opening && !host.canReopen)
    #expect(host.hasUncertainPublication && host.recoveryMessage.contains("Do not repeat it"))
    host.reopen()
    await host.drain()
    verifyFailedUncertainReopen(host: host, workspace: workspace, before: before)
    counts = await probe.counts()
    #expect(counts.opens == 2 && counts.writes == 2)
    for _ in 0..<5 {
      _ = host.recoveryMessage
      _ = host.recoveryDiagnostics
    }
    counts = await probe.counts()
    #expect(counts.opens == 2 && counts.writes == 2)
  }

  private func verifyHealthyWorkspaceCannotReopen(
    host: NativeHost, workspace: WorkspaceModel, probe: NativeRecoveryProbe
  ) async throws {
    host.reopen()
    await host.drain()
    var counts = await probe.counts()
    #expect(counts.opens == 3 && counts.writes == 2)
    await workspace.close()
    #expect(host.canReopen)
    let token = try #require(host.beginQuit())
    #expect(!host.canReopen)
    host.reopen()
    await host.drain()
    counts = await probe.counts()
    #expect(counts.opens == 3 && counts.writes == 2)
    host.finishQuit(token, cancelled: true)
    #expect(host.canReopen)
  }

  private func verifyFailedUncertainReopen(
    host: NativeHost, workspace: WorkspaceModel, before: LibrarySnapshot
  ) {
    #expect(workspace.issue == .busy && workspace.availability == .blocked)
    #expect(workspace.snapshot == before)
    #expect(host.reopenFailure != nil && host.track.failure == nil)
    #expect(host.hasUncertainPublication && host.hasRecoveryFeedback && host.canReopen)
    #expect(host.recoveryMessage.contains("may or may not have been saved"))
    #expect(host.recoveryMessage.contains("Do not repeat it"))
    #expect(host.recoveryMessage.contains("or assume it is safe to discard"))
    #expect(host.recoveryDiagnostics.contains("Unresolved publication uncertainty:"))
    #expect(host.recoveryDiagnostics.contains("Last explicit reopen error (historical):"))
  }

  private func verifyHealthyUncertainReopen(host: NativeHost, workspace: WorkspaceModel) {
    #expect(host.available && !host.canReopen && workspace.issue == nil)
    #expect(!host.hasUncertainPublication && host.reopenFailure == nil)
    #expect(!host.recoveryMessage.contains("may or may not"))
    #expect(!host.recoveryDiagnostics.contains("Last explicit reopen error"))
    #expect(host.track.failure == "Unsent draft error sentinel")
    #expect(
      host.recoveryDiagnostics.contains(
        "Last editor/action error (historical; inspect the affected draft):"))
    #expect(host.recoveryMessage.contains("historical feedback"))
  }

  @Test(arguments: [false, true])
  func acceptedSuccessorCannotEraseUncertaintyBeforeHostReopen(storageFailure: Bool) async throws {
    let directory = fixtureTemporaryDirectory().appendingPathComponent(
      "RecoveryQueued.\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "NativeRecovery.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let probe = NativeRecoveryProbe()
    var operations = WorkspaceOperations()
    operations.open = { try await probe.open($0) }
    operations.perform = { try await probe.perform($0, $1, $2) }
    let workspace = WorkspaceModel(directory: directory, operations: operations)
    let host = NativeHost(directory: directory, workspace: workspace, defaults: defaults)
    defer { host.invalidate() }
    host.reopen()
    await host.drain()
    let before = try #require(workspace.snapshot)
    #expect(!workspace.publicationUncertain && !host.hasUncertainPublication)
    if storageFailure {
      await probe.setFailWrite(StorageError.commitIndeterminate)
    } else {
      await probe.setFailWrite()
    }
    // Both accepted on MainActor without first suspension: the successor runs in the real FIFO.
    let uncertain = workspace.enqueueSubmit(
      .createProject(id: UUID(), name: "Unknown", rate: 1, currency: "EUR"),
      expectedRevision: before.revision)
    let successor = workspace.enqueueSubmit(
      .createProject(id: UUID(), name: "Must not write", rate: 1, currency: "EUR"),
      expectedRevision: before.revision)
    #expect(workspace.isBusy)
    await verifyUncertainAndSuccessorErrors(
      uncertain: uncertain, successor: successor, storageFailure: storageFailure)
    verifyQueuedUncertainty(host: host, workspace: workspace, before: before)
    var counts = await probe.counts()
    #expect(counts.opens == 1 && counts.writes == 1)
    await probe.setOpenError(LibraryOpenError.busy)
    host.reopen()
    #expect(workspace.publicationUncertain && host.hasUncertainPublication)
    await host.drain()
    verifySuccessorReopenFailure(host: host, workspace: workspace, before: before)
    counts = await probe.counts()
    #expect(counts.opens == 2 && counts.writes == 1)
    await verifyCloseKeepsUncertainty(host: host, workspace: workspace, probe: probe)
    await probe.setOpenError(nil)
    host.reopen()
    #expect(workspace.publicationUncertain && host.hasUncertainPublication)
    await host.drain()
    verifySuccessorHealthyReopen(host: host, workspace: workspace, before: before)
    counts = await probe.counts()
    #expect(counts.opens == 3 && counts.writes == 1)  // Inspection never replays either queued mutation.
    await workspace.close()
  }

  private func verifyUncertainAndSuccessorErrors(
    uncertain: Task<LibrarySnapshot, Error>, successor: Task<LibrarySnapshot, Error>, storageFailure: Bool
  ) async {
    do {
      _ = try await uncertain.value
      Issue.record("Expected uncertain publication")
    } catch {
      if storageFailure {
        #expect((error as? StorageError) == .commitIndeterminate)
      } else {
        #expect((error as? LibraryAccessError) == .publicationIndeterminate)
      }
    }
    do {
      _ = try await successor.value
      Issue.record("Expected queued successor to fail before its writer")
    } catch { #expect((error as? LibraryAccessError) == .unavailable) }
  }

  private func verifyCloseKeepsUncertainty(
    host: NativeHost, workspace: WorkspaceModel, probe: NativeRecoveryProbe
  ) async {
    await workspace.close()
    #expect(workspace.issue == nil && workspace.snapshot == nil)
    #expect(workspace.publicationUncertain && host.hasUncertainPublication)  // Shutdown is not confirmation.
    let counts = await probe.counts()
    #expect(counts.opens == 2 && counts.writes == 1)
  }

  private func verifyQueuedUncertainty(
    host: NativeHost, workspace: WorkspaceModel, before: LibrarySnapshot
  ) {
    // No host.reopen has occurred since the uncertain write. Its old capture-only latch would miss this.
    #expect(workspace.issue == .unavailable && workspace.availability == .blocked)
    #expect(workspace.snapshot == before && !workspace.isBusy)
    #expect(workspace.publicationUncertain && host.hasUncertainPublication)
    #expect(host.recoveryMessage.contains("Do not repeat it"))
  }

  private func verifySuccessorReopenFailure(
    host: NativeHost, workspace: WorkspaceModel, before: LibrarySnapshot
  ) {
    #expect(workspace.issue == .busy && workspace.snapshot == before)
    #expect(workspace.publicationUncertain && host.hasUncertainPublication)
    #expect(host.reopenFailure != nil && host.canReopen)
    #expect(host.recoveryMessage.contains("or assume it is safe to discard"))
  }

  private func verifySuccessorHealthyReopen(
    host: NativeHost, workspace: WorkspaceModel, before: LibrarySnapshot
  ) {
    #expect(host.available && workspace.snapshot == before && workspace.issue == nil)
    #expect(!workspace.publicationUncertain && !host.hasUncertainPublication)
    #expect(host.reopenFailure == nil)
  }

  private func verifyOpenFailureDiagnostics(
    host: NativeHost, workspace: WorkspaceModel, probe: NativeRecoveryProbe
  ) async throws {
    #expect(host.reopenFailure != nil && host.track.failure == nil)
    #expect(host.recoveryDiagnostics.contains("Last explicit reopen error (historical):"))
    for _ in 0..<3 {
      _ = host.recoveryMessage
      _ = host.recoveryDiagnostics
    }
    let counts = await probe.counts()
    #expect(counts.opens == 1 && counts.writes == 0)
    await workspace.close()
  }

}
