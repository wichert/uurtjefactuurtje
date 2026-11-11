import Foundation
import Testing

@testable import LibraryStore
@testable import UurtjeFactuurtje

final class NativeClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Int64 = 100
  func read() -> Int64 { lock.withLock { value } }
  func set(_ value: Int64) { lock.withLock { self.value = value } }
}

func fixtureTemporaryDirectory() -> URL {
  let path = FileManager.default.temporaryDirectory.path
  // /var is first symlink; sandbox container paths already name real directories.
  return URL(fileURLWithPath: path.hasPrefix("/var/") ? "/private" + path : path, isDirectory: true)
}

@MainActor func withTrack(_ body: (TrackPresentation, URL) async throws -> Void) async throws {
  let directory = fixtureTemporaryDirectory().appendingPathComponent(
    UUID().uuidString, isDirectory: true)
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
@MainActor @discardableResult func project(_ track: TrackPresentation, name: String = "Project")
  async throws -> UUID {
  let id = UUID()
  let seconds = try #require(track.workspace.snapshot)
  _ = try await track.workspace.submit(
    .createProject(id: id, name: name, rate: 50, currency: "EUR"),
    expectedRevision: seconds.revision)
  return id
}
@MainActor @discardableResult func task(
  _ track: TrackPresentation, project: UUID, parent: UUID? = nil, name: String = "Task"
) async throws -> UUID {
  let id = UUID()
  let seconds = try #require(track.workspace.snapshot)
  _ = try await track.workspace.enqueueTaskCreation(
    TaskCreationRequest(
      id: id, projectID: project, parentID: parent, name: name, confirmMigration: false,
      start: false), expectedRevision: seconds.revision
  ).value
  return id
}
