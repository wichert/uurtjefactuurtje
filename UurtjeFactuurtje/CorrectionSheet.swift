import SwiftUI
import LibraryStore

struct WallTimeFields: View {
    let title: String
    @Binding var value: LocalCorrectionTime
    let calendar: Calendar
    private func component(_ key: WritableKeyPath<DateComponents, Int?>) -> Binding<String> {
        Binding(get: { value.components[keyPath: key].map(String.init) ?? "" }, set: {
            value.components[keyPath: key] = Int($0); value.selectedInstant = nil
        })
    }
    var body: some View {
        GroupBox(title) {
            HStack {
                TextField("Year", text: component(\.year))
                TextField("Month", text: component(\.month))
                TextField("Day", text: component(\.day))
                TextField("Hour", text: component(\.hour))
                TextField("Minute", text: component(\.minute))
                TextField("Second", text: component(\.second))
            }
            switch CorrectionClock.resolve(value.components, calendar: calendar) {
            case .nonexistent: Text("Invalid or nonexistent local time; choose another time.").foregroundStyle(.red)
            case .unique(let instant): Text(EntryDisclosure.bound(instant, zone: calendar.timeZone)).textSelection(.enabled)
            case .ambiguous(let earlier, let later, let firstOffset, let secondOffset):
                Picker("Repeated time — choose an offset explicitly", selection: $value.selectedInstant) {
                    Text("Choose offset").tag(Int64?.none)
                    Text("Earlier \(CorrectionClock.offsetText(firstOffset))").tag(Optional(earlier))
                    Text("Later \(CorrectionClock.offsetText(secondOffset))").tag(Optional(later))
                }
            }
        }
    }
}
struct EntryDisclosure: View {
    let entry: TimeEntry
    let path: String
    let zone: TimeZone
    static func bound(_ seconds: Int64, zone: TimeZone) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone; formatter.dateFormat = "yyyy-MM-dd HH:mm:ss XXXXX"
        return "\(formatter.string(from: date)) [saved \(seconds)]"
    }
    var body: some View {
        VStack(alignment: .leading) {
            Text(path); Text("Entry \(entry.id.uuidString)")
            Text("Start: \(Self.bound(entry.startAt, zone: zone))")
            Text(entry.endAt.map { "End: \(Self.bound($0, zone: zone))" } ?? "Open — Stop or review; not editable")
        }.textSelection(.enabled)
    }
}
struct AdjustmentDisclosure: View {
    let preview: CorrectionPreview
    let zone: TimeZone
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let source = preview.source { EntryDisclosure(entry: source, path: "Source: " + (preview.sourcePath?.text ?? "Unavailable"), zone: zone) }
            switch preview.draft {
            case .add(let id, let task, let start, let end), .edit(let id, let task, let start, let end):
                EntryDisclosure(entry: TimeEntry(id: id, taskID: task, startAt: start, endAt: end), path: "Destination: " + preview.targetPath.text, zone: zone)
            }
            ForEach(preview.adjustments, id: \.before.id) { adjustment in
                GroupBox(adjustment.kind.rawValue) {
                    EntryDisclosure(entry: adjustment.before, path: adjustment.path.text, zone: zone)
                    if adjustment.retained.isEmpty { Text("Entire row will be deleted.") }
                    ForEach(adjustment.retained) { EntryDisclosure(entry: $0, path: "Retained (including split identity)", zone: zone) }
                }
            }
            if let conflict = preview.runningConflict {
                EntryDisclosure(entry: conflict, path: "Running conflict: " + (preview.runningPath?.text ?? "Unavailable"), zone: zone)
                Text("Stop the owned timer, then Review again. Stopping does not confirm this preview.")
            }
        }
    }
}
struct CorrectionSheet: View {
    let presentation: TrackPresentation
    let route: CorrectionRoute
    let token: UUID
    @State private var form: CorrectionForm?
    @State private var error: String?
    private var model: WorkspaceModel { presentation.workspace }
    var body: some View {
        ScrollView {
            if let form { contents(form) }
            else { Text(error ?? "Loading entry…").textSelection(.enabled) }
        }.padding().frame(minWidth: 580, idealHeight: 650)
        .task(id: token) {
            guard form == nil, let s = model.snapshot else { return }
            do { form = try CorrectionForm(route: route, snapshot: s, now: Date()) }
            catch { self.error = String(describing: error) }
        }
        .onChange(of: model.snapshot?.revision) { _, _ in form?.invalidateConfirmation() }
    }
    @ViewBuilder private func contents(_ form: CorrectionForm) -> some View {
        @Bindable var form = form
        VStack(alignment: .leading, spacing: 12) {
            Text(form.source == nil ? "Add time" : "Edit whole saved entry").font(.headline)
            Text("Frozen zone: \(form.timeZone.identifier)")
            Picker("Time zone", selection: $form.timeZone) {
                ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { id in Text(id).tag(TimeZone(identifier: id)!) }
            }
            Picker("Task", selection: $form.taskID) {
                Text("Select leaf").tag(UUID?.none)
                ForEach(model.snapshot?.tasks ?? []) { task in
                    if allowed(task, form: form) { Text(presentation.path(task.id)).tag(Optional(task.id)) }
                }
            }
            WallTimeFields(title: "Start", value: $form.start, calendar: form.calendar)
            WallTimeFields(title: "End", value: $form.end, calendar: form.calendar)
            if let duration = try? form.duration() { Text("Duration: \(duration) seconds") }
            if let preview = form.preview { AdjustmentDisclosure(preview: preview, zone: form.timeZone) }
            if let deletion = form.deletion { EntryDisclosure(entry: deletion.entry, path: "Delete whole entry: " + deletion.path.text, zone: form.timeZone) }
            if form.confirmationIsStale { Text("Preview is stale. The old disclosure is retained; Review again before confirming.") }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel") { presentation.cancelSheet() }.keyboardShortcut(.cancelAction)
                Button("Back") { form.back() }
                Button("Review") { review(form, deletion: false) }
                if form.source != nil { Button("Review deletion", role: .destructive) { review(form, deletion: true) } }
                if form.preview?.runningConflict != nil, let stop = presentation.ownedStop {
                    Button("Stop, then review again") { presentation.timer(stop) { form.invalidateConfirmation() } }
                }
                Button(form.deletion == nil ? "Confirm changes" : "Confirm deletion", role: form.deletion == nil ? nil : .destructive) { confirm(form) }
                    .disabled(form.confirmationIsStale || (form.preview == nil && form.deletion == nil) || form.preview?.runningConflict != nil)
            }
        }.disabled(presentation.acceptedWork)
    }
    private func allowed(_ task: TaskRecord, form: CorrectionForm) -> Bool {
        guard let s = model.snapshot, !s.tasks.contains(where: { $0.parentTaskID == task.id }) else { return false }
        if let source = form.source { return s.tasks.first(where: { $0.id == source.taskID })?.projectID == task.projectID }
        return presentation.eligible(task.id)
    }
    private func review(_ form: CorrectionForm, deletion: Bool) {
        guard let s = model.snapshot else { return }
        do { if deletion { try form.reviewDeletion(in: s) } else { try form.review(in: s) }; error = nil }
        catch { self.error = String(describing: error); form.invalidateConfirmation() }
    }
    private func confirm(_ form: CorrectionForm) {
        guard !form.confirmationIsStale else { return }
        let command: CorrectionCommand
        if let deletion = form.deletion { command = .delete(deletion) }
        else if let preview = form.preview, preview.runningConflict == nil { command = .apply(preview) }
        else { return }
        guard presentation.begin(token) else { return }
        let result = model.enqueueCorrection(command)
        Task { @MainActor in
            do { _ = try await result.value; presentation.complete(token) }
            catch { self.error = String(describing: error); form.invalidateConfirmation(); presentation.complete(token, error: error) }
        }
    }
}
