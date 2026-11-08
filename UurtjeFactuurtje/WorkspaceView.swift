import SwiftUI
import LibraryStore

struct WorkspaceView<ReportsContent: View>: View {
    @Bindable private var presentation: TrackPresentation
    private let reports: () -> ReportsContent
    init(presentation: TrackPresentation, @ViewBuilder reports: @escaping () -> ReportsContent) {
        self.presentation = presentation; self.reports = reports
    }
    var body: some View {
        VStack(spacing: 0) {
            Picker("Destination", selection: $presentation.destination) {
                Text("Track").tag(WorkspaceDestination.track)
                Text("Reports").tag(WorkspaceDestination.reports)
            }.pickerStyle(.segmented).padding()
            WorkspaceFeedback(presentation: presentation)
            switch presentation.destination {
            case .track: TrackView(presentation: presentation)
            case .reports: reports()
            }
        }
        .sheet(item: Binding(get: { presentation.sheet }, set: { if $0 == nil { presentation.cancelSheet() } })) { route in
            editor(route, token: presentation.routeToken)
                .id(presentation.routeToken)
                .interactiveDismissDisabled(presentation.acceptedWork)
        }
        .onChange(of: presentation.workspace.snapshot?.revision, initial: true) { _, _ in presentation.reconcile() }
    }
    @ViewBuilder private func editor(_ route: TrackSheet, token: UUID) -> some View {
        switch route {
        case .project(let draft): ProjectSheet(presentation: presentation, token: token, draft: draft)
        case .task(let draft): TaskSheet(presentation: presentation, token: token, draft: draft)
        case .correction(let route): CorrectionSheet(presentation: presentation, route: route, token: token)
        case .timeReview: TimeReviewView(presentation: presentation, token: token)
        }
    }
}

struct WorkspaceFeedback: View {
    let presentation: TrackPresentation
    private var model: WorkspaceModel { presentation.workspace }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isBusy || presentation.acceptedWork { ProgressView("Saving accepted work…") }
            if let message = presentation.feedback {
                HStack { Text(message).textSelection(.enabled); Button("Dismiss message") { presentation.feedback = nil } }
            }
            if let failure = presentation.failure { Text(failure).textSelection(.enabled).foregroundStyle(.red) }
            if let issue = model.issue { Text("Workspace: \(String(describing: issue))").textSelection(.enabled) }
            if model.availability == .blocked || model.availability == .closed {
                Text("Last confirmed rows only. Save outcome may be uncertain. Copy the library location and checkpoint below; reopen and inspect before any retry. Do not blindly replay the failed command.")
                Text("Default library location: \(URL.applicationSupportDirectory.appendingPathComponent("UurtjeFactuurtje", isDirectory: true).path)").textSelection(.enabled)
                Text("If this host uses an injected location, obtain that URL from the host before restoring files. Do not restore into an assumed directory.")
                if let active = model.snapshot?.activeTimer { Text("Checkpoint: \(active.checkpointAt), entry \(active.entryID)").textSelection(.enabled) }
                Button("Explicitly reopen and inspect (no replay)") {
                    Task { @MainActor in do { try await model.open() } catch { presentation.failure = String(describing: error) } }
                }.disabled(model.isBusy || presentation.acceptedWork)
            }
            ForEach(model.budgetWarnings) { batch in
                GroupBox("Committed budget warning") {
                    ForEach(batch.warnings, id: \.taskID) { warning in
                        HStack {
                            Text("\(presentation.path(warning.taskID)): lifetime budget \(warning.threshold.rawValue)% reached")
                            Button("Reveal task") { presentation.revealTask(warning.taskID) }
                        }
                    }
                    Button("Dismiss this warning batch") { model.dismissBudgetWarning(batch.id) }
                }
            }
        }.padding(.horizontal)
    }
}
