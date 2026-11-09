import SwiftUI
import AppKit
import LibraryStore

struct WallTimeFields: View {
    let title: String
    @Binding var value: LocalCorrectionTime
    let calendar: Calendar

    private var selection: Binding<Date> {
        Binding(get: { CorrectionForm.pickerDate(for: value) }, set: { date in
            let changed = CorrectionForm.applyingPickerDate(date, to: value)
            if changed != value { value = changed }
        })
    }

    private var occurrence: Binding<Int64?> {
        Binding(get: { value.selectedInstant }, set: { instant in
            let changed = CorrectionForm.choosingOccurrence(instant, for: value, calendar: calendar)
            if changed != value { value = changed }
        })
    }

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                DatePicker("\(title) date and time", selection: selection,
                           displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.field)
                    .environment(\.calendar, CorrectionForm.pickerCalendar)
                    .environment(\.timeZone, CorrectionForm.pickerCalendar.timeZone)
                switch CorrectionClock.resolve(value.components, calendar: calendar) {
                case .nonexistent:
                    Text("This local time does not exist in the captured time zone. Choose another time.")
                        .foregroundStyle(.red)
                case .unique(let instant):
                    Text(EntryDisclosure.bound(instant, zone: calendar.timeZone)).textSelection(.enabled)
                case .ambiguous(let earlier, let later, let firstOffset, let secondOffset):
                    Picker("Repeated local time — choose an occurrence", selection: occurrence) {
                        Text("Choose occurrence").tag(Int64?.none)
                        Text("Earlier occurrence — \(EntryDisclosure.offset(firstOffset))").tag(Optional(earlier))
                        Text("Later occurrence — \(EntryDisclosure.offset(secondOffset))").tag(Optional(later))
                    }
                }
            }
        }
    }
}
struct EntryDisclosure: View {
    let entry: TimeEntry
    let path: String
    let zone: TimeZone
    static func offset(_ offset: Int) -> String {
        let magnitude = offset.magnitude
        let text = String(format: "UTC%@%02llu:%02llu", offset < 0 ? "−" : "+",
                          magnitude / 3600, magnitude / 60 % 60)
        return magnitude % 60 == 0 ? text : "approximately \(text) (historical offset)"
    }

    static func bound(_ seconds: Int64, zone: TimeZone) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(formatter.string(from: date)) — \(zone.identifier), \(offset(zone.secondsFromGMT(for: date)))"
    }

    static func durationText(_ duration: Int64) -> String {
        if duration > 0 && duration < 60 { return "less than a minute" }
        let minutes = duration / 60
        let value = "\(minutes / 60) h \(minutes % 60) min"
        return duration % 60 == 0 ? value : "approximately \(value)"
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text(path)
            Text("Start: \(Self.bound(entry.startAt, zone: zone))")
            Text(entry.endAt.map { "End: \(Self.bound($0, zone: zone))" }
                 ?? "Open — Stop or review; not editable")
            if let stop = entry.endAt {
                Text("Duration: \(Self.durationText(stop - entry.startAt))")
            }
            Text("Minute-level display. Saved boundaries retain their exact stored precision unless explicitly changed.")
                .font(.caption)
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
        let editing = form.preview == nil && form.deletion == nil
        VStack(alignment: .leading, spacing: 12) {
            Text(form.source == nil ? "Add time" : "Edit whole saved entry").font(.headline)
            Text("Time zone captured when opened: \(form.timeZone.identifier)")
            if editing {
                Picker("Task", selection: $form.taskID) {
                    Text("Select leaf").tag(UUID?.none)
                    ForEach(model.snapshot?.tasks ?? []) { task in
                        if allowed(task, form: form) {
                            Text(presentation.path(task.id)).tag(Optional(task.id))
                        }
                    }
                }
                WallTimeFields(title: "Start", value: $form.start, calendar: form.calendar)
                WallTimeFields(title: "End", value: $form.end, calendar: form.calendar)
                Text("Unchanged saved boundaries retain exact stored precision. Changing a boundary uses minute precision.")
                Text("Native input can normalize dates or retain the previous value for an incomplete edit. Review the resulting values before confirming.")
            } else {
                Text("Review the resulting dates, times, occurrence offsets and affected entries. Confirm accepts these values, including any native date normalization. Use Back to change them.")
            }
            if let preview = form.preview { AdjustmentDisclosure(preview: preview, zone: form.timeZone) }
            if let deletion = form.deletion {
                EntryDisclosure(entry: deletion.entry,
                    path: "Delete whole entry: " + deletion.path.text, zone: form.timeZone)
            }
            if form.confirmationIsStale {
                Text("Preview is stale. The old disclosure is retained; use Back and Review again before confirming.")
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel") { presentation.cancelSheet() }.keyboardShortcut(.cancelAction)
                if editing {
                    Button("Review") { review(form, deletion: false) }
                    if form.source != nil {
                        Button("Review deletion", role: .destructive) { review(form, deletion: true) }
                    }
                } else {
                    Button("Back") { form.back() }
                    if form.preview?.runningConflict != nil, let stop = presentation.ownedStop {
                        Button("Stop, then review again") {
                            presentation.timer(stop) { form.invalidateConfirmation() }
                        }
                    }
                    Button(form.deletion == nil ? "Confirm changes" : "Confirm deletion",
                           role: form.deletion == nil ? nil : .destructive) { confirm(form) }
                        .disabled(form.confirmationIsStale || form.preview?.runningConflict != nil)
                }
            }
        }.disabled(presentation.acceptedWork)
    }
    private func allowed(_ task: TaskRecord, form: CorrectionForm) -> Bool {
        guard let s = model.snapshot, !s.tasks.contains(where: { $0.parentTaskID == task.id }) else { return false }
        if let source = form.source { return s.tasks.first(where: { $0.id == source.taskID })?.projectID == task.projectID }
        return presentation.eligible(task.id)
    }
    private func review(_ form: CorrectionForm, deletion: Bool) {
        guard NSApp.keyWindow?.makeFirstResponder(nil) == true else {
            error = "Finish editing the date and time before reviewing."
            return
        }
        DispatchQueue.main.async {
            guard !presentation.acceptedWork, let s = model.snapshot else { return }
            do {
                if deletion { try form.reviewDeletion(in: s) }
                else { try form.review(in: s) }
                error = nil
            } catch {
                self.error = String(describing: error)
                form.invalidateConfirmation()
            }
        }
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
