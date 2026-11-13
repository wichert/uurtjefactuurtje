import LibraryStore
import SwiftUI

// No grouping or exponent syntax: a rate is a complete localized decimal, never a numeric prefix.
enum RateInput {
    static func text(_ value: Decimal, locale: Locale = .current) -> String {
        var copy = value
        return NSDecimalString(&copy, Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }
    static func parse(_ text: String, locale: Locale = .current) -> Decimal? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = locale.decimalSeparator ?? "."
        let parts = raw.components(separatedBy: separator)
        guard parts.count <= 2, !parts.isEmpty,
            parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } })
        else {
            return nil
        }
        let canonical = parts.joined(separator: ".")
        guard let decimal = Decimal(string: canonical, locale: Locale(identifier: "en_US_POSIX")),
            !decimal.isNaN
        else { return nil }
        func normalized(_ input: String) -> String {
            let pieces = input.components(separatedBy: ".")
            let integer = String(pieces[0].drop(while: { $0 == "0" }))
            let fraction = pieces.count == 2 ? String(pieces[1].reversed().drop(while: { $0 == "0" }).reversed()) : ""
            return (integer.isEmpty ? "0" : integer) + (fraction.isEmpty ? "" : "." + fraction)
        }
        // Foundation may round Decimal(string:); exact round-trip equality is mandatory for money.
        let rendered = normalized(Self.text(decimal, locale: Locale(identifier: "en_US_POSIX")))
        guard normalized(canonical) == rendered else { return nil }
        return decimal
    }
}

struct ProjectSheet: View {
    let presentation: TrackPresentation
    let token: UUID
    @State var draft: ProjectDraft
    @State private var error: String?
    @State private var refreshedSnapshot: LibrarySnapshot?
    private var model: WorkspaceModel { presentation.workspace }
    private var reviewedSnapshot: LibrarySnapshot? { refreshedSnapshot ?? draft.reviewedSnapshot }
    private var libraryChanged: Bool {
        guard let latest = model.snapshot else { return true }
        if let reviewedSnapshot { return !reviewedSnapshot.editorRelevantEquals(latest) }
        return latest.revision != draft.observedRevision
    }
    var body: some View {
        Form {
            Section(draft.isNew ? "New project" : "Edit project") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                    TextField("Name", text: $draft.name).labelsHidden().accessibilityLabel("Project name")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hourly rate")
                    TextField("Hourly rate", text: $draft.rateText)
                        .labelsHidden().accessibilityLabel("Hourly rate")
                        .frame(maxWidth: 200, alignment: .leading)
                    Text(
                        "Enter a nonnegative decimal using your Mac's decimal separator; "
                            + "no grouping separators."
                    )
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !draft.isNew {
                        Text(
                            "Changing the hourly rate recalculates all saved time in this project at the new rate, "
                                + "including historical reports. It does not preserve past rates."
                        )
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Currency")
                    TextField("ISO currency code", text: $draft.currencyCode)
                        .labelsHidden().accessibilityLabel("ISO currency code")
                        .frame(maxWidth: 100, alignment: .leading)
                    Text(
                        "Use an uppercase ISO code, for example EUR or USD. "
                            + "No currency conversion is performed."
                    )
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let original = model.snapshot?.projects.first(where: { $0.id == draft.id }),
                    original.currencyCode != draft.currencyCode {
                    Toggle(
                        isOn: Binding(
                            get: { draft.confirmedPreviousCurrency == original.currencyCode },
                            set: { draft.confirmedPreviousCurrency = $0 ? original.currencyCode : nil })
                    ) {
                        Text("Relabel all history from \(original.currencyCode); no currency conversion")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if libraryChanged {
                Section("Review required") {
                    Text("Library changed. Review these fields against the confirmed rows before retrying.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("I reviewed the latest project") {
                        guard let latest = model.snapshot else { return }
                        refreshedSnapshot = latest
                        draft.confirmedPreviousCurrency = nil
                        draft.archiveConfirmed = false
                    }
                }
            }
            if !draft.isNew, let project = model.snapshot?.projects.first(where: { $0.id == draft.id }) {
                Section("Availability") {
                    Toggle(isOn: $draft.archiveConfirmed) {
                        Text(
                            project.isArchived
                                ? "Confirm restoring this project"
                                : "Confirm archive; history is retained"
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(project.isArchived ? "Restore project" : "Archive project") {
                        save(archive: !project.isArchived)
                    }
                    .disabled(!draft.archiveConfirmed)
                    if let active = model.snapshot?.activeTimer,
                        let entry = model.snapshot?.entries.first(where: { $0.id == active.entryID }),
                        model.snapshot?.tasks.first(where: { $0.id == entry.taskID })?.projectID == draft.id {
                        Text(
                            "Stop or review this project's timer before archiving. "
                                + "Archive is never silently combined with Stop."
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section {
                if let error {
                    Text(error).textSelection(.enabled).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Cancel") { presentation.cancelSheet() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") { save(archive: nil) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.bordered)
        .textInputBorderShape(.roundedRectangle)
        .frame(
            minWidth: 360, idealWidth: 480, maxWidth: 560,
            minHeight: 280, idealHeight: 440, maxHeight: 520
        )
        .disabled(presentation.acceptedWork)
        .onChange(of: draft.currencyCode) { _, _ in draft.confirmedPreviousCurrency = nil }
    }
    private func save(archive: Bool?) {
        guard let latest = model.snapshot, !libraryChanged else {
            error = "Review the changed library first."
            return
        }
        let command: WorkspaceCommand
        if let archive {
            guard draft.archiveConfirmed else { return }
            command = .setArchived(id: draft.id, archived: archive)
        } else {
            if let message = draft.inputError(in: latest) {
                error = message
                return
            }
            guard let rate = RateInput.parse(draft.rateText) else {
                error = "Enter a nonnegative decimal rate without grouping separators."
                return
            }
            if draft.isNew {
                command = .createProject(id: draft.id, name: draft.name, rate: rate, currency: draft.currencyCode)
            } else {
                command = .updateProject(
                    id: draft.id, name: draft.name, rate: rate, currency: draft.currencyCode,
                    confirmedPreviousCurrency: draft.confirmedPreviousCurrency)
            }
        }
        guard presentation.begin(token) else { return }
        let result = model.enqueueSubmit(
            command, expectedRevision: latest.revision,
            reviewedSnapshot: reviewedSnapshot)
        Task { @MainActor in
            do {
                _ = try await result.value
                presentation.complete(token)
            } catch {
                self.error = String(describing: error)
                presentation.complete(token, error: error)
            }
        }
    }
}

struct TaskSheet: View {
    let presentation: TrackPresentation
    let token: UUID
    @State var draft: TaskDraft
    @State private var error: String?
    private var model: WorkspaceModel { presentation.workspace }
    private var libraryChanged: Bool {
        guard let latest = model.snapshot else { return true }
        if let reviewed = draft.reviewedSnapshot { return !reviewed.editorRelevantEquals(latest) }
        return latest.revision != draft.observedRevision
    }
    private var location: String {
        if !draft.isNew { return presentation.path(draft.id) }
        if let parent = draft.parentID { return presentation.path(parent) }
        return model.snapshot?.projects.first(where: { $0.id == draft.projectID })?.name ?? "Missing project"
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(draft.isNew ? "New task" : "Edit task").font(.headline)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Location").font(.subheadline).foregroundStyle(.secondary)
                        Text(location).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name")
                        TextField("Task name", text: $draft.name)
                            .labelsHidden().accessibilityLabel("Task name")
                    }
                    Toggle("Lifetime budget (optional)", isOn: $draft.budgetEnabled)
                    if draft.budgetEnabled {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Budget (hours)")
                            HStack {
                                TextField("For example \(BudgetInput.text(150))", text: $draft.budgetHours)
                                    .labelsHidden().accessibilityLabel("Lifetime budget in hours")
                                    .frame(maxWidth: 200)
                                Button {
                                    draft.stepBudget(by: -30)
                                    sync()
                                } label: {
                                    Image(systemName: "minus")
                                }
                                .accessibilityLabel("Decrease budget by 30 minutes")
                                .help("Decrease by 0.5 hours (30 minutes)")
                                .disabled(draft.budgetAfterStep(by: -30) == nil)
                                Button {
                                    draft.stepBudget(by: 30)
                                    sync()
                                } label: {
                                    Image(systemName: "plus")
                                }
                                .accessibilityLabel("Increase budget by 30 minutes")
                                .help("Increase by 0.5 hours (30 minutes)")
                                .disabled(draft.budgetAfterStep(by: 30) == nil)
                            }
                            constraints
                        }
                    }
                    if draft.isNew && needsMigration {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                "Move this parent's saved entries and pending sleep to an ordinary Generic child. "
                                    + "Pending sleep stays unbilled."
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            Toggle("I confirm migration of entries and pending sleep", isOn: $draft.migrationAccepted)
                        }
                    }
                    if libraryChanged {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Library changed. Review fields, location and budget constraints before resubmitting.")
                                .fixedSize(horizontal: false, vertical: true)
                            Button("I reviewed the latest task and constraints") {
                                guard let latest = model.snapshot else { return }
                                draft.reviewedSnapshot = latest
                                draft.observedRevision = latest.revision
                                draft.migrationAccepted = false
                                sync()
                            }
                        }
                    }
                    if let error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
            Divider()
            HStack {
                Button("Cancel") { presentation.cancelSheet() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(draft.isNew ? "Create" : "Save") { save(start: false) }.keyboardShortcut(.defaultAction)
                if draft.isNew { Button("Create & Start") { save(start: true) } }
            }
            .padding(20)
        }
        .textFieldStyle(.bordered)
        .textInputBorderShape(.roundedRectangle)
        .frame(minWidth: 400, idealWidth: 480, maxWidth: 560)
        .frame(minHeight: 280, idealHeight: 440, maxHeight: 560)
        .disabled(presentation.acceptedWork)
        .onChange(of: draft.name) { _, _ in sync() }
        .onChange(of: draft.budgetHours) { _, _ in sync() }
        .onChange(of: draft.budgetEnabled) { _, _ in sync() }
        .onChange(of: draft.migrationAccepted) { _, _ in sync() }
        .onChange(of: draft.projectID) { _, _ in sync() }
        .onChange(of: draft.parentID) { _, _ in sync() }
    }
    private var needsMigration: Bool {
        guard let snapshot = model.snapshot, let parent = draft.parentID,
            !snapshot.tasks.contains(where: { $0.parentTaskID == parent })
        else { return false }
        return snapshot.entries.contains { $0.taskID == parent }
            || snapshot.pendingSleepIntervals.contains { $0.taskID == parent }
    }
    @ViewBuilder private var constraints: some View {
        if let snapshot = model.snapshot {
            switch Result(catching: {
                try BudgetRules.allowance(
                    in: snapshot, projectID: draft.projectID,
                    parentTaskID: draft.parentID, editingTaskID: draft.isNew ? nil : draft.id)
            }) {
            case .success(let allowance):
                let minimum = ReportFormatting.budgetHours(seconds: allowance.minimumMinutes * 60)
                let maximum = allowance.maximumMinutes.map { ReportFormatting.budgetHours(seconds: $0 * 60) }
                Text("Range: \(minimum)–\(maximum ?? "unlimited"). Whole minutes; lifetime budget.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let id = allowance.limitingAncestorID {
                    Button {
                        sync()
                        presentation.editConstrainingBudget(taskID: id)
                    } label: {
                        Text("Edit limiting budget: \(presentation.path(id))")
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.link)
                    .accessibilityLabel("Edit limiting budget: \(presentation.path(id))")
                }
            case .failure(let error):
                Text(String(describing: error)).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func sync() { presentation.updateTaskDraft(draft) }
    private func save(start: Bool) {
        guard let latest = model.snapshot, !libraryChanged else {
            error = "Review the changed library first."
            return
        }
        if let message = draft.inputError(in: latest) {
            error = message
            return
        }
        guard !needsMigration || draft.migrationAccepted else {
            error = "Confirm entry and pending-sleep migration."
            return
        }
        sync()
        guard presentation.begin(token) else { return }
        if draft.isNew {
            let result = model.enqueueTaskCreation(
                draft.request(start: start), expectedRevision: draft.observedRevision,
                reviewedSnapshot: draft.reviewedSnapshot)
            Task { @MainActor in
                do {
                    let creation = try await result.value
                    guard token == presentation.routeToken else { return }
                    presentation.feedback =
                        creation.genericID.map {
                            "Created Generic \($0): moved \(creation.movedEntryCount) entries and "
                                + "\(creation.movedPendingCount) pending intervals."
                        } ?? "Task created."
                    presentation.complete(token)
                } catch {
                    self.error = String(describing: error)
                    presentation.complete(token, error: error)
                }
            }
        } else {
            let result = model.enqueueSubmit(
                .editTask(id: draft.id, name: draft.name, budgetMinutes: draft.parsedBudget),
                expectedRevision: draft.observedRevision, reviewedSnapshot: draft.reviewedSnapshot)
            Task { @MainActor in
                do {
                    _ = try await result.value
                    presentation.complete(token)
                } catch {
                    self.error = String(describing: error)
                    presentation.complete(token, error: error)
                }
            }
        }
    }
}
