import AppKit
import SwiftUI

@main struct UurtjeFactuurtjeApp: App {
    @NSApplicationDelegateAdaptor(Lifecycle.self) private var delegate

    var body: some Scene {
        Window("UurtjeFactuurtje", id: "workspace") {
            WorkspaceView(host: delegate.host) {
                ReportsView(reports: delegate.host.reports)
            }
            .disabled(delegate.host.quitAttempt != nil)
            .frame(minWidth: 720, minHeight: 450)
            .overlay {
                if delegate.host.quitAttempt != nil {
                    ProgressView("Finishing accepted work before quitting…")
                        .padding()
                        .background(.regularMaterial)
                }
            }
        }
        .defaultSize(width: 900, height: 600)
        .commands { NativeCommands(host: delegate.host) }
        Settings {
            SettingsView(host: delegate.host)
                .disabled(delegate.host.quitAttempt != nil)
        }
    }
}

@MainActor private struct NativeCommands: Commands {
    let host: NativeHost
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    init(host: NativeHost) {
        self.host = host
    }

    var body: some Commands {
        // Commands exist even without a workspace view; never install from onAppear.
        let _: Void = host.installSceneActions(
            workspace: {
                openWindow(id: "workspace")
                NSApp.activate(ignoringOtherApps: true)
            },
            settings: {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            })
        CommandGroup(after: .windowArrangement) {
            Button("Open Track") {
                host.openTrack()
            }
            Button("Open Reports") {
                host.openReports()
            }
            Button("Review time…") {
                host.openReview()
            }
        }
    }
}
