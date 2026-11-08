import SwiftUI
import LibraryStore

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
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let canonical = parts.joined(separator: ".")
        guard let decimal = Decimal(string: canonical, locale: Locale(identifier: "en_US_POSIX")), !decimal.isNaN else { return nil }
        func normalized(_ input: String) -> String {
            let pieces = input.components(separatedBy: ".")
            let integer = String(pieces[0].drop(while: { $0 == "0" }))
            let fraction = pieces.count == 2 ? String(pieces[1].reversed().drop(while: { $0 == "0" }).reversed()) : ""
            return (integer.isEmpty ? "0" : integer) + (fraction.isEmpty ? "" : "." + fraction)
        }
        // Foundation may round Decimal(string:); exact round-trip equality is mandatory for money.
        guard normalized(canonical) == normalized(self.text(decimal, locale: Locale(identifier: "en_US_POSIX"))) else { return nil }
        return decimal
    }
}

struct ProjectSheet: View {
    let presentation: TrackPresentation
    let token: UUID
    @State var draft: ProjectDraft
    @State private var error: String?
    @State private var refreshedRevision: Int64?
    private var model: WorkspaceModel { presentation.workspace }
    var body: some View {
        Form {
            Text(draft.isNew ? "New project" : "Edit project").font(.headline)
            TextField("Name", text: $draft.name)
            TextField("Hourly rate (exact decimal, no grouping)", text: $draft.rateText)
            TextField("ISO currency code", text: $draft.currencyCode)
            if let original = model.snapshot?.projects.first(where: { $0.id == draft.id }), original.currencyCode != draft.currencyCode {
                Toggle("Relabel all history from \(original.currencyCode); no currency conversion", isOn: Binding(
                    get: { draft.confirmedPreviousCurrency == original.currencyCode },
                    set: { draft.confirmedPreviousCurrency = $0 ? original.currencyCode : nil }))
            }
            if model.snapshot?.revision != (refreshedRevision ?? draft.observedRevision) {
                Text("Library changed. Review these fields against the confirmed rows before retrying.")
                Button("I reviewed the latest project") { refreshedRevision = model.snapshot?.revision; draft.confirmedPreviousCurrency = nil; draft.archiveConfirmed = false }
            }
            if !draft.isNew, let project = model.snapshot?.projects.first(where: { $0.id == draft.id }) {
                Toggle(project.isArchived ? "Confirm restoring this project" : "Confirm archive; history is retained", isOn: $draft.archiveConfirmed)
                Button(project.isArchived ? "Restore project" : "Archive project") { save(archive: !project.isArchived) }
                    .disabled(!draft.archiveConfirmed)
                if let active = model.snapshot?.activeTimer,
                   let entry = model.snapshot?.entries.first(where: { $0.id == active.entryID }),
                   model.snapshot?.tasks.first(where: { $0.id == entry.taskID })?.projectID == draft.id {
                    Text("Stop or review this project's timer before archiving. Archive is never silently combined with Stop.")
                }
            }
            if let error { Text(error).textSelection(.enabled).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { presentation.cancelSheet() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(archive: nil) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding().frame(minWidth: 420).disabled(presentation.acceptedWork)
        .onChange(of: draft.currencyCode) { _, _ in draft.confirmedPreviousCurrency = nil }
    }
    private func save(archive: Bool?) {
        guard let revision = model.snapshot?.revision,
              revision == (refreshedRevision ?? draft.observedRevision) else { error = "Review the changed library first."; return }
        guard let rate = RateInput.parse(draft.rateText) else { error = "Enter a complete, nonnegative, exactly representable localized decimal rate."; return }
        let command: WorkspaceCommand
        if let archive {
            guard draft.archiveConfirmed else { return }
            command = .setArchived(id: draft.id, archived: archive)
        } else if draft.isNew {
            command = .createProject(id: draft.id, name: draft.name, rate: rate, currency: draft.currencyCode)
        } else {
            command = .updateProject(id: draft.id, name: draft.name, rate: rate, currency: draft.currencyCode,
                                     confirmedPreviousCurrency: draft.confirmedPreviousCurrency)
        }
        guard presentation.begin(token) else { return }
        let first = draft.isNew && model.snapshot?.projects.isEmpty == true
        let result = model.enqueueSubmit(command, expectedRevision: revision)
        Task { @MainActor in
            do {
                _ = try await result.value
                presentation.complete(token)
                if first, presentation.sheet == nil { presentation.selectedProjectID = draft.id; presentation.newTask(projectID: draft.id) }
            } catch { self.error = String(describing: error); presentation.complete(token, error: error) }
        }
    }
}

struct TaskSheet: View {
    let presentation: TrackPresentation
    let token: UUID
    @State var draft: TaskDraft
    @State private var error: String?
    private var model: WorkspaceModel { presentation.workspace }
    var body: some View {
        Form {
            Text(draft.isNew ? "New task" : "Edit task").font(.headline)
            TextField("Name", text: $draft.name)
            if draft.isNew {
                Picker("Project", selection: Binding(get: { draft.projectID }, set: { draft.relocate(projectID: $0, parentID: nil) })) {
                    ForEach((model.snapshot?.projects ?? []).filter { !$0.isArchived }) { Text($0.name).tag($0.id) }
                }
                Picker("Parent", selection: Binding(get: { draft.parentID }, set: { draft.relocate(projectID: draft.projectID, parentID: $0) })) {
                    Text("Project root").tag(UUID?.none)
                    ForEach(presentation.allRows(projectID: draft.projectID)) { Text($0.path).tag(Optional($0.id)) }
                }
                Text("New tasks start without a budget. Edit the created task to set one.")
                if needsMigration {
                    Text("This leaf owns saved entries or pending sleep. Move all of them to an ordinary Generic child; pending sleep stays unbilled.")
                    Toggle("I confirm migration of entries and pending sleep", isOn: $draft.migrationAccepted)
                }
            } else {
                Text(presentation.path(draft.id)).textSelection(.enabled)
                Toggle("Lifetime budget", isOn: $draft.budgetEnabled)
                if draft.budgetEnabled { TextField("Hours", text: $draft.budgetHours) }
            }
            constraints
            if model.snapshot?.revision != draft.observedRevision {
                Text("Library changed. Review fields, location and budget constraints before resubmitting.")
                Button("I reviewed the latest task and constraints") {
                    draft.observedRevision = model.snapshot?.revision ?? draft.observedRevision
                    draft.migrationAccepted = false
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel") { presentation.cancelSheet() }.keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Create" : "Save") { save(start: false) }.keyboardShortcut(.defaultAction)
                if draft.isNew { Button("Create & Start") { save(start: true) } }
            }
        }.padding().frame(minWidth: 440).disabled(presentation.acceptedWork)
        .onChange(of: draft.name) { _, _ in sync() }
        .onChange(of: draft.budgetHours) { _, _ in sync() }
        .onChange(of: draft.budgetEnabled) { _, _ in sync() }
        .onChange(of: draft.projectID) { _, _ in sync() }
        .onChange(of: draft.parentID) { _, _ in sync() }
    }
    private var needsMigration: Bool {
        guard let s = model.snapshot, let parent = draft.parentID,
              !s.tasks.contains(where: { $0.parentTaskID == parent }) else { return false }
        return s.entries.contains { $0.taskID == parent } || s.pendingSleepIntervals.contains { $0.taskID == parent }
    }
    @ViewBuilder private var constraints: some View {
        if let s = model.snapshot {
            switch Result(catching: { try BudgetRules.allowance(in: s, projectID: draft.projectID, parentTaskID: draft.parentID, editingTaskID: draft.isNew ? nil : draft.id) }) {
            case .success(let allowance):
                Text("Descendant frontier minimum: \(allowance.minimumSeconds.description) seconds")
                Text("Maximum: \(allowance.maximumSeconds?.description ?? "unbounded") seconds")
                if let id = allowance.limitingAncestorID {
                    Button("Edit limiting budget: \(presentation.path(id))") { sync(); presentation.editConstrainingBudget(taskID: id) }
                }
            case .failure(let error): Text(String(describing: error)).textSelection(.enabled)
            }
            switch Result(catching: { try BudgetRules.allocations(in: s) }) {
            case .success(let allocations):
                ForEach(allocations.filter { $0.taskID == draft.id || $0.taskID == draft.parentID }, id: \.taskID) { item in
                    Text("\(presentation.path(item.taskID)): allocated \(item.allocatedSeconds.description) / \(item.limitSeconds) seconds")
                }
            case .failure(let error): Text(String(describing: error)).textSelection(.enabled)
            }
        }
    }
    private func sync() { presentation.updateTaskDraft(draft) }
    private func save(start: Bool) {
        guard draft.observedRevision == model.snapshot?.revision else { error = "Review the changed library first."; return }
        guard !needsMigration || draft.migrationAccepted else { error = "Confirm entry and pending-sleep migration."; return }
        guard draft.isNew || !draft.budgetEnabled || draft.parsedBudget != nil else { error = "Budget must be positive whole seconds expressed in localized hours."; return }
        sync()
        guard presentation.begin(token) else { return }
        if draft.isNew {
            let result = model.enqueueTaskCreation(draft.request(start: start), expectedRevision: draft.observedRevision)
            Task { @MainActor in
                do {
                    let creation = try await result.value
                    presentation.feedback = creation.genericID.map { "Created Generic \($0): moved \(creation.movedEntryCount) entries and \(creation.movedPendingCount) pending intervals." } ?? "Task created."
                    presentation.complete(token)
                } catch { self.error = String(describing: error); presentation.complete(token, error: error) }
            }
        } else {
            let result = model.enqueueSubmit(.editTask(id: draft.id, name: draft.name, budgetSeconds: draft.parsedBudget), expectedRevision: draft.observedRevision)
            Task { @MainActor in
                do {
                    _ = try await result.value
                    presentation.complete(token)
                } catch { self.error = String(describing: error); presentation.complete(token, error: error) }
            }
        }
    }
}
