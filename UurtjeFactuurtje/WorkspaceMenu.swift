import SwiftUI
import AppKit
import LibraryStore

struct WorkspaceMenu: View {
    let host: NativeHost
    @State private var query = ""
    private var track: TrackPresentation { host.track }
    private static let autocompleteLimit = 8

    private static func eligibleTasks(_ track: TrackPresentation) -> [TaskRow] {
        track.projects.flatMap { track.allRows(projectID: $0.id) }
            .filter { track.eligible($0.id) }
    }

    static func recentTasks(_ track: TrackPresentation, limit: Int = 2) -> [UUID] {
        guard limit > 0 else { return [] }
        var seen = Set<UUID>()
        return (track.workspace.snapshot?.entries ?? []).sorted { $0.startAt > $1.startAt }
            .map(\.taskID).filter { track.eligible($0) && seen.insert($0).inserted }
            .prefix(limit).map { $0 }
    }

    static func matchingTasks(_ track: TrackPresentation, query: String,
                              limit: Int = autocompleteLimit) -> [UUID] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        return eligibleTasks(track)
            .filter { $0.path.localizedStandardContains(trimmed) }
            .map(\.id).prefix(limit).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let stop = track.ownedStop {
                Button("Stop tracking") { host.submitTimer(stop) }
                    .disabled(!host.acceptingMutations)
            }
            if !Self.recentTasks(track).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent tasks").font(.headline)
                    ForEach(Self.recentTasks(track), id: \.self) { id in
                        taskButton(id, accessibilityPrefix: "Start tracking") {
                            host.submitTimer(.start(taskID: id))
                        }
                        .disabled(!host.acceptingMutations)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Open a task").font(.headline)
                TextField("Find a leaf task", text: $query)
                    .textFieldStyle(.bordered).textInputBorderShape(.roundedRectangle)
                    .accessibilityLabel("Find a leaf task to open")
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let matches = Self.matchingTasks(track, query: query)
                    if matches.isEmpty {
                        Text("No eligible leaf tasks match.").foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(matches, id: \.self) { id in
                                    taskButton(id, accessibilityPrefix: "Open") {
                                        host.revealNotificationTask(id)
                                        query = ""
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                    }
                }
            }
            if host.hasRecoveryFeedback {
                ScrollView { WorkspaceRecovery(host: host) }.frame(maxHeight: 140)
            }
            Divider()
            Button("Open UurtjeFactuurtje") { host.openTrack() }
            Button("Quit UurtjeFactuurtje…") { NSApp.terminate(nil) }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func taskButton(_ id: UUID, accessibilityPrefix: String,
                                         action: @escaping () -> Void) -> some View {
        if let task = host.workspace.snapshot?.tasks.first(where: { $0.id == id }) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(accessibilityPrefix == "Start tracking" ? "Start \(task.name)" : task.name).font(.headline)
                    Text(track.path(id)).font(.caption).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(accessibilityPrefix): \(track.path(id))")
            .help(track.path(id))
        }
    }
}
