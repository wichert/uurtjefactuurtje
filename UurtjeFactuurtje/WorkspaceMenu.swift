import SwiftUI
import AppKit
import LibraryStore

struct WorkspaceMenu: View {
    let host: NativeHost
    @State private var query = ""
    private var track: TrackPresentation { host.track }
    static func tasks(_ track: TrackPresentation, query: String) -> [UUID] {
        let eligible = track.projects.flatMap { track.allRows(projectID: $0.id) }
            .filter { track.eligible($0.id) }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return eligible.filter { $0.path.localizedStandardContains(query) }.map(\.id)
        }
        var seen = Set<UUID>()
        return (track.workspace.snapshot?.entries ?? []).sorted { $0.startAt > $1.startAt }
            .map(\.taskID).filter { track.eligible($0) && seen.insert($0).inserted }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let count = host.workspace.snapshot?.pendingSleepIntervals.count, count > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(count) pending sleep interval(s) — unbilled")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Review pending time…") { host.openReview() }
                }
                .accessibilityElement(children: .contain)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let active = host.workspace.snapshot?.activeTimer,
                       let entry = host.workspace.snapshot?.entries.first(where: { $0.id == active.entryID }) {
                        Text(track.path(entry.taskID))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if let stop = track.ownedStop {
                        Button("Stop tracking") { host.submitTimer(stop) }
                            .disabled(!host.acceptingMutations)
                    }
                    TextField("Search eligible tasks", text: $query)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(query.isEmpty ? "Recent tasks" : "Search results").font(.headline)
                        ForEach(Self.tasks(track, query: query), id: \.self) { id in
                            if let task = host.workspace.snapshot?.tasks.first(where: { $0.id == id }) {
                                Button {
                                    host.submitTimer(.start(taskID: id))
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(task.name).font(.headline)
                                        Text(track.path(id)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .accessibilityLabel("Start tracking: \(track.path(id))")
                                .help(track.path(id))
                                .disabled(!host.acceptingMutations || !host.available)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Button("New task…") { host.newTask() }
                        Button("New project…") { host.newProject() }
                        Button("Add time…") { host.addTime() }
                    }.disabled(!host.acceptingMutations)
                    ForEach(host.workspace.budgetWarnings) { batch in
                        ForEach(batch.warnings, id: \.taskID) { warning in
                            Button("\(track.path(warning.taskID)): budget \(warning.threshold.rawValue)% — reveal") {
                                host.revealNotificationTask(warning.taskID)
                            }
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    WorkspaceRecovery(host: host)
                    Divider()
                    Button("Open Track") { host.openTrack() }
                    Button("Open Reports") { host.openReports() }
                    Button("Review time…") { host.openReview() }
                    Button("Settings…") { host.openSettings() }
                    Button("Quit UurtjeFactuurtje…") { NSApp.terminate(nil) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
