import AppKit
import LibraryStore
import SwiftUI

struct WallTimeFields: View {
    let title: String
    @Binding var value: LocalCorrectionTime
    let calendar: Calendar

    private var selection: Binding<Date> {
        Binding(
            get: { CorrectionForm.pickerDate(for: value) },
            set: { date in
                let changed = CorrectionForm.applyingPickerDate(date, to: value)
                if changed != value { value = changed }
            })
    }

    private var occurrence: Binding<Int64?> {
        Binding(
            get: { value.selectedInstant },
            set: { instant in
                let changed = CorrectionForm.choosingOccurrence(instant, for: value, calendar: calendar)
                if changed != value { value = changed }
            })
    }

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                DatePicker(
                    "\(title) date and time", selection: selection,
                    displayedComponents: [.date, .hourAndMinute]
                )
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
        let text = String(
            format: "UTC%@%02llu:%02llu", offset < 0 ? "−" : "+",
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
        return "\(formatter.string(from: date)) — \(zone.identifier), "
            + offset(zone.secondsFromGMT(for: date))
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
            Text(
                entry.endAt.map { "End: \(Self.bound($0, zone: zone))" }
                    ?? "Open — Stop or review; not editable")
            if let stop = entry.endAt {
                Text("Duration: \(Self.durationText(stop - entry.startAt))")
            }
            Text(
                "Minute-level display. Saved boundaries retain their exact stored precision "
                    + "unless explicitly changed."
            )
            .font(.caption)
        }.textSelection(.enabled)
    }
}
struct AdjustmentDisclosure: View {
    let preview: CorrectionPreview
    let zone: TimeZone
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let source = preview.source {
                EntryDisclosure(
                    entry: source,
                    path: "Source: " + (preview.sourcePath?.text ?? "Unavailable"), zone: zone)
            }
            switch preview.draft {
            case .add(let id, let task, let start, let end), .edit(let id, let task, let start, let end):
                EntryDisclosure(
                    entry: TimeEntry(id: id, taskID: task, startAt: start, endAt: end),
                    path: "Destination: " + preview.targetPath.text, zone: zone)
            }
            ForEach(preview.adjustments, id: \.before.id) { adjustment in
                GroupBox(adjustment.kind.rawValue) {
                    EntryDisclosure(entry: adjustment.before, path: adjustment.path.text, zone: zone)
                    if adjustment.retained.isEmpty { Text("Entire row will be deleted.") }
                    ForEach(adjustment.retained) {
                        EntryDisclosure(
                            entry: $0,
                            path: "Retained (including split identity)", zone: zone)
                    }
                }
            }
            if let conflict = preview.runningConflict {
                EntryDisclosure(
                    entry: conflict,
                    path: "Running conflict: " + (preview.runningPath?.text ?? "Unavailable"),
                    zone: zone)
                Text("Stop the owned timer, then Review again. Stopping does not confirm this preview.")
            }
        }
    }
}
struct SimpleTimeField: View {
    let title: String
    @Binding var value: LocalCorrectionTime
    let calendar: Calendar

    private var selection: Binding<Date> {
        Binding(
            get: { CorrectionForm.pickerDate(for: value) },
            set: { date in
                let changed = CorrectionForm.applyingPickerDate(date, to: value)
                if changed != value { value = changed }
            })
    }

    private var occurrence: Binding<Int64?> {
        Binding(
            get: { value.selectedInstant },
            set: { instant in
                let changed = CorrectionForm.choosingOccurrence(instant, for: value, calendar: calendar)
                if changed != value { value = changed }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DatePicker(
                title,
                selection: selection,
                displayedComponents: [.hourAndMinute]
            )
            .datePickerStyle(.field)
            .environment(\.calendar, CorrectionForm.pickerCalendar)
            .environment(\.timeZone, CorrectionForm.pickerCalendar.timeZone)

            switch CorrectionClock.resolve(value.components, calendar: calendar) {
            case .nonexistent:
                Text("This local time does not exist in the current time zone. Choose another time.")
                    .foregroundStyle(.red)
                    .font(.caption)
            case .unique:
                EmptyView()
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

struct SimpleDeletionSummary: View {
    let deletion: DeletionPreview
    let calendar: Calendar
    @Environment(\.locale) private var locale

    private var taskTitle: String {
        let name = deletion.path.taskNames.joined(separator: " / ")
        return name.isEmpty ? "—" : name
    }

    var body: some View {
        let entry = deletion.entry
        let endAt = entry.endAt ?? entry.startAt
        let startTime = ReportFormatting.timeOfDay(entry.startAt, calendar: calendar, locale: locale)
        let endTime = ReportFormatting.timeOfDay(endAt, calendar: calendar, locale: locale)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Project:").foregroundStyle(.secondary)
                Text(deletion.path.projectName)
            }
            GridRow {
                Text("Task:").foregroundStyle(.secondary)
                Text(taskTitle)
            }
            GridRow {
                Text("Date:").foregroundStyle(.secondary)
                Text(ReportFormatting.date(entry.startAt, calendar: calendar, locale: locale))
            }
            GridRow {
                Text("Time:").foregroundStyle(.secondary)
                Text("\(startTime) to \(endTime)")
            }
            GridRow {
                Text("Duration:").foregroundStyle(.secondary)
                Text(ReportFormatting.totalTime(seconds: max(0, endAt - entry.startAt)))
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
        Group {
            if let form {
                contents(form)
            } else {
                Text(error ?? "Loading entry…").textSelection(.enabled)
            }
        }
        .padding(16)
        .fixedSize()
        .task(id: token) {
            guard form == nil, let snapshot = model.snapshot else { return }
            do { form = try CorrectionForm(route: route, snapshot: snapshot, now: Date()) } catch {
                self.error = String(describing: error)
            }
        }
        .onChange(of: model.snapshot?.revision) { _, _ in form?.invalidateConfirmation() }
    }
    @ViewBuilder private func contents(_ form: CorrectionForm) -> some View {
        @Bindable var form = form
        let editing = form.deletion == nil
        let title: String = {
            if form.deletion != nil { return "Delete work entry" }
            return form.source == nil ? "Add time" : "Edit work entry"
        }()
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            if editing {
                Picker("Task", selection: $form.taskID) {
                    Text("Select leaf").tag(UUID?.none)
                    ForEach(model.snapshot?.tasks ?? []) { task in
                        if allowed(task, form: form) {
                            Text(presentation.path(task.id)).tag(Optional(task.id))
                        }
                    }
                }
                SimpleTimeField(title: "Start time", value: $form.start, calendar: form.calendar)
                SimpleTimeField(title: "End time", value: $form.end, calendar: form.calendar)
            }
            if let deletion = form.deletion {
                SimpleDeletionSummary(deletion: deletion, calendar: form.calendar)
            }
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions(form, editing: editing)
        }
        .frame(minWidth: 260, alignment: .leading)
        .disabled(presentation.acceptedWork)
    }

    @ViewBuilder private func actions(_ form: CorrectionForm, editing: Bool) -> some View {
        HStack {
            Button("Cancel") { presentation.cancelSheet() }.keyboardShortcut(.cancelAction)
            Spacer()
            if editing {
                Button("Save") { save(form) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Delete") { confirm(form) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(form.confirmationIsStale)
            }
        }
    }

    private func allowed(_ task: TaskRecord, form: CorrectionForm) -> Bool {
        guard let snapshot = model.snapshot,
            !snapshot.tasks.contains(where: { $0.parentTaskID == task.id })
        else { return false }
        if let source = form.source {
            return snapshot.tasks.first(where: { $0.id == source.taskID })?.projectID == task.projectID
        }
        return presentation.eligible(task.id)
    }

    private func save(_ form: CorrectionForm) {
        if let window = NSApp.keyWindow, !window.makeFirstResponder(nil) {
            error = "Finish editing the time before saving."
            return
        }
        DispatchQueue.main.async {
            guard !presentation.acceptedWork, let snapshot = model.snapshot else { return }
            do {
                try form.review(in: snapshot)
                if form.preview?.runningConflict != nil {
                    form.back()
                    error = "This time range overlaps with the running timer. Stop the timer first."
                    return
                }
                error = nil
                confirm(form)
            } catch {
                self.error = String(describing: error)
                form.back()
            }
        }
    }

    private func confirm(_ form: CorrectionForm) {
        guard !form.confirmationIsStale else { return }
        let command: CorrectionCommand
        if let deletion = form.deletion {
            command = .delete(deletion)
        } else if let preview = form.preview,
            preview.runningConflict == nil {
            command = .apply(preview)
        } else {
            return
        }
        guard presentation.begin(token) else { return }
        let result = model.enqueueCorrection(command)
        Task { @MainActor in
            do {
                _ = try await result.value
                presentation.complete(token)
            } catch {
                self.error = String(describing: error)
                form.invalidateConfirmation()
                presentation.complete(token, error: error)
            }
        }
    }
}
