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
            if let active = host.workspace.snapshot?.activeTimer,
               let entry = host.workspace.snapshot?.entries.first(where: { $0.id == active.entryID }) {
                Text(track.path(entry.taskID)).textSelection(.enabled)
            }
            if let stop = track.ownedStop {
                Button("Stop tracking") { host.submitTimer(stop) }.disabled(!host.acceptingMutations)
            }
            TextField("Search eligible tasks", text: $query)
            ScrollView {
                VStack(alignment: .leading) {
                    Text(query.isEmpty ? "Recent tasks" : "Search results").font(.headline)
                    ForEach(Self.tasks(track, query: query), id: \.self) { id in
                        Button("Start: \(track.path(id))") { host.submitTimer(.start(taskID: id)) }
                            .disabled(!host.acceptingMutations || !host.available)
                    }
                }
            }.frame(maxHeight: 180)
            HStack {
                Button("New task…") { host.newTask() }
                Button("New project…") { host.newProject() }
                Button("Add time…") { host.addTime() }
            }.disabled(!host.acceptingMutations)
            ForEach(host.workspace.budgetWarnings) { batch in
                ForEach(batch.warnings, id: \.taskID) { warning in
                    Button("\(track.path(warning.taskID)): budget \(warning.threshold.rawValue)% — reveal") {
                        host.revealNotificationTask(warning.taskID)
                    }
                }
            }
            if let error = track.failure { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let issue = host.workspace.issue { Text(String(describing: issue)).textSelection(.enabled) }
            if !host.available {
                Text("Workspace \(String(describing: host.workspace.availability)). Inspect before retrying; no automatic replay.")
                Text(host.recoveryDetails.isEmpty ? host.directory.path : host.recoveryDetails).textSelection(.enabled)
                Button("Explicitly reopen and inspect") { host.reopen() }.disabled(host.quitAttempt != nil || host.workspace.isBusy)
            }
            Divider()
            Button("Open Track") { host.openTrack() }
            Button("Open Reports") { host.openReports() }
            Button("Review time…") { host.openReview() }
            Button("Settings…") { host.openSettings() }
            Button("Quit UurtjeFactuurtje…") { NSApp.terminate(nil) }
        }.padding().frame(width: 420)
    }
}
