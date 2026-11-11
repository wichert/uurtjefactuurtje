import SwiftUI
import AppKit
import LibraryStore

struct WorkspaceView<ReportsContent: View>: View {
    @Bindable private var presentation: TrackPresentation
    private let host: NativeHost
    private let reports: () -> ReportsContent
    init(host: NativeHost, @ViewBuilder reports: @escaping () -> ReportsContent) {
        self.host = host
        self.presentation = host.track
        self.reports = reports
    }
    var body: some View {
        VStack(spacing: 0) {
            Picker("Destination", selection: $presentation.destination) {
                Text("Track").tag(WorkspaceDestination.track)
                Text("Reports").tag(WorkspaceDestination.reports)
            }.pickerStyle(.segmented).padding()
            WorkspaceFeedback(host: host)
            if host.available, presentation.workspace.snapshot != nil {
                switch presentation.destination {
                case .track:
                    TrackView(presentation: presentation) { projectID, taskID in
                        host.openProjectReport(projectID: projectID, scopeTaskID: taskID)
                    }
                case .reports: reports()
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Workspace unavailable").font(.headline)
                    Text("""
                        Use the library feedback above. Tracking and reports will return \
                        when the library is available.
                        """)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding()
            }
        }
        .sheet(
            item: Binding(
                get: { presentation.sheet },
                set: { if $0 == nil { presentation.cancelSheet() } },
            )
        ) { route in
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
    let host: NativeHost
    private var presentation: TrackPresentation { host.track }
    private var model: WorkspaceModel { host.workspace }
    private var hasFeedback: Bool {
        model.isBusy || presentation.acceptedWork || host.hasRecoveryFeedback
    }
    var body: some View {
        if hasFeedback {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if model.isBusy || presentation.acceptedWork {
                        ProgressView(model.availability == .opening ? "Opening library…" : "Finishing accepted work…")
                    }
                    WorkspaceRecovery(host: host)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .padding(.horizontal)
        }
    }
}

struct WorkspaceRecovery: View {
    let host: NativeHost
    var body: some View {
        if host.hasRecoveryFeedback {
            VStack(alignment: .leading, spacing: 6) {
                Text(host.recoveryMessage)
                    .fixedSize(horizontal: false, vertical: true)
                if host.workspace.snapshot != nil && !host.available {
                    Text("""
                        Any retained rows are the last confirmed view and may be stale, \
                        not proof that the last change was saved.
                        """)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if host.canReopen {
                    Button("Reopen library and inspect (no replay)") { host.reopen() }
                }
                if host.available, host.workspace.snapshot != nil {
                    if host.workspace.availability == .reviewRequired || host.workspace.issue == .recoveryRequired {
                        Button("Review time…") { host.openReview() }
                    } else if host.hasUncertainPublication || host.workspace.issue != nil
                        || host.reopenFailure != nil || host.track.failure != nil {
                        Button("Open Track to inspect") { host.openTrack() }
                    }
                }
                Button("Copy library location") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(host.directory.path, forType: .string)
                }
                DisclosureGroup("Diagnostic details") {
                    Text(host.recoveryDiagnostics)
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
