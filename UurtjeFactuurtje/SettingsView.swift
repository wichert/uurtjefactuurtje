import LibraryStore
import SwiftUI

@MainActor
struct SettingsView: View {
    let host: NativeHost
    private var model: WorkspaceModel { host.workspace }
    @State private var isSaving = false
    @State private var saveError: String?

    private var available: Bool {
        model.availability == .ready || model.availability == .reviewRequired
    }

    var body: some View {
        Form {
            Section("Reports") {
                if let weekday = model.firstWeekday {
                    Picker(
                        "Week starts on",
                        selection: Binding(
                            get: { model.firstWeekday ?? weekday },
                            set: save
                        )
                    ) {
                        ForEach(1...7, id: \.self) { day in
                            Text(Calendar.current.standaloneWeekdaySymbols[day - 1]).tag(day)
                        }
                    }
                    .accessibilityLabel("Week starts on")
                    .disabled(isSaving || model.isBusy || !available)
                } else {
                    LabeledContent("Week starts on", value: "Unavailable")
                        .accessibilityLabel("Week starts on, unavailable")
                }
                Text(
                    """
                    Applies to weekly reports and each project's This week period. \
                    Dates and times use your Mac's time zone.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                if isSaving {
                    ProgressView("Saving week preference…")
                        .accessibilityLabel("Saving week preference")
                }
                if let saveError {
                    Text(saveError)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Week preference error: \(saveError)")
                } else if !available {
                    Text("Preferences are unavailable. Open or reopen the library from the main window.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Billing") {
                Text("Hourly rates and currencies belong to each project. Reports do not convert between currencies.")
            }
            Section("Warnings") {
                Text(
                    """
                    In-app budget warnings work without notification permission. Manage macOS notifications \
                    and Focus in System Settings; those settings can silence external notifications.
                    """)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, idealWidth: 480)
        .padding()
    }

    private func save(_ weekday: Int) {
        guard !isSaving, !model.isBusy, available,
            model.firstWeekday != nil, weekday != model.firstWeekday
        else { return }
        guard let accepted = host.submitFirstWeekday(weekday) else { return }
        isSaving = true
        saveError = nil
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await accepted.value
            } catch {
                if model.availability == .blocked {
                    saveError = """
                        The save could not be confirmed. Reopen the library from the main window before trying again.
                        """
                } else {
                    saveError = """
                        The preference was not saved. Your previous selection is unchanged. \
                        Check the library's location and try again.
                        """
                }
            }
        }
    }
}
