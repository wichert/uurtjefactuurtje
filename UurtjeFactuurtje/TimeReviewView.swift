import AppKit
import LibraryStore
import SwiftUI

struct TimeReviewView: View {
    let presentation: TrackPresentation
    let token: UUID
    @State private var selectedPending: UUID?
    @State private var end: LocalCorrectionTime?
    @State private var zone = TimeZone.current
    @State private var command: TimeReviewCommand?
    @State private var inclusion: CorrectionPreview?
    @State private var summary: String?
    @State private var stale = false
    @State private var error: String?
    private var model: WorkspaceModel { presentation.workspace }
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
    private var pending: [PendingSleepInterval] {
        (model.snapshot?.pendingSleepIntervals ?? []).sorted {
            $0.sleepAt == $1.sleepAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.sleepAt < $1.sleepAt
        }
    }
    private var interrupted: Bool {
        switch model.timerStatus {
        case .paused, .reviewRequired:
            model.snapshot?.activeTimer != nil
        default:
            false
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Review unconfirmed time").font(.headline)
                Text("Pending sleep is not billed. Resolving an interruption stays stopped.")
                Text("Time zone captured when opened: \(zone.identifier)")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if command == nil {
                        Picker("Review item", selection: $selectedPending) {
                            if interrupted { Text("Interrupted active entry").tag(UUID?.none) }
                            ForEach(pending) { row in
                                let label =
                                    "\(presentation.path(row.taskID)) — "
                                    + EntryDisclosure.bound(row.sleepAt, zone: zone)
                                Text(label).tag(Optional(row.id))
                            }
                        }
                        if let row = pending.first(where: { $0.id == selectedPending }) {
                            Text(presentation.path(row.taskID)).textSelection(.enabled)
                            Text("Sleep: \(EntryDisclosure.bound(row.sleepAt, zone: zone))")
                            Text(
                                row.wakeAt.map { "Saved wake: \(EntryDisclosure.bound($0, zone: zone))" }
                                    ?? "End unknown — enter an explicit end; nothing is inferred from now.")
                            if row.wakeAt == nil { endFields }
                            HStack {
                                Button("Review Include") { plan(skip: false) }
                                Button("Review Skip", role: .destructive) { plan(skip: true) }
                            }
                        } else if interrupted, let active = model.snapshot?.activeTimer,
                            let entry = model.snapshot?.entries.first(where: { $0.id == active.entryID }) {
                            EntryDisclosure(
                                entry: entry,
                                path: presentation.path(entry.taskID),
                                zone: zone,
                            )
                            let checkpoint = EntryDisclosure.bound(active.checkpointAt, zone: zone)
                            let duration = EntryDisclosure.durationText(active.checkpointAt - entry.startAt)
                            Text("Durable checkpoint: \(checkpoint)")
                            Text("Checkpointed duration: \(duration)")
                            Text(
                                """
                                Explicit discard removes this interrupted entry and all its checkpointed time; \
                                nothing is saved and tracking stays stopped.
                                """)
                            endFields
                            HStack {
                                Button("Review Save & Stop") { plan(skip: false) }
                                Button("Review explicit discard", role: .destructive) { plan(skip: true) }
                            }
                        } else {
                            Text(
                                "No selected review item. Choose a pending interval,"
                                    + " or there is nothing to resolve.")
                        }
                        Text(
                            """
                            Native input can normalize dates or retain the previous value for an incomplete edit. \
                            Review the resulting values before confirming.
                            """)
                    } else {
                        Text(
                            """
                            Review the resulting dates, times, occurrence offsets and affected entries. \
                            Confirm accepts these values, including any native date normalization. \
                            Use Back to change them.
                            """)
                    }
                    Text(
                        """
                        Minute-level display. Unchanged saved boundaries retain exact stored precision; \
                        newly entered ends use minute precision.
                        """)
                    if let summary { Text(summary).textSelection(.enabled) }
                    if let inclusion { AdjustmentDisclosure(preview: inclusion, zone: zone) }
                    if stale {
                        Text(
                            """
                            Evidence changed or a submission failed. Use Back and Review again; \
                            old disclosure is retained.
                            """)
                    }
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button("Cancel") { presentation.cancelSheet() }.keyboardShortcut(.cancelAction)
                if command != nil {
                    Button("Back") {
                        command = nil
                        inclusion = nil
                        summary = nil
                        stale = false
                    }
                    if inclusion?.runningConflict != nil, let stop = presentation.ownedStop {
                        Button("Stop, then review again") { presentation.timer(stop) { stale = true } }
                    }
                    Button("Confirm reviewed action") { confirm() }
                        .disabled(stale || inclusion?.runningConflict != nil)
                }
            }
        }
        .disabled(presentation.acceptedWork)
        .padding().frame(minWidth: 580, idealHeight: 650)
        .onAppear {
            selectedPending = interrupted ? nil : pending.first?.id
            resetEnd()
        }
        .onChange(of: selectedPending) { _, _ in
            command = nil
            inclusion = nil
            summary = nil
            resetEnd()
        }
        .onChange(of: end) { _, _ in if command != nil { stale = true } }
        .onChange(of: model.snapshot?.revision) { _, _ in if command != nil { stale = true } }
    }
    @ViewBuilder private var endFields: some View {
        if end != nil {
            WallTimeFields(
                title: "Explicit end",
                value: Binding(get: { end! }, set: { end = $0 }),
                calendar: calendar,
            )
        } else {
            Button("Enter an explicit unknown end") {
                // Start with the boundary, not launch/now; equal bounds cannot accidentally include a gap.
                if let row = pending.first(where: { $0.id == selectedPending }) {
                    let date = Date(timeIntervalSince1970: TimeInterval(row.sleepAt))
                    end = CorrectionForm.fields(
                        date,
                        calendar: calendar,
                        preservingPrecision: false,
                    )
                }
            }
        }
    }
    private func resetEnd() {
        end = nil
        stale = false
        if selectedPending == nil, interrupted, let checkpoint = model.snapshot?.activeTimer?.checkpointAt {
            end = CorrectionForm.fields(
                Date(timeIntervalSince1970: TimeInterval(checkpoint)),
                calendar: calendar,
                preservingPrecision: true,
            )
        }
    }
    private func plan(skip: Bool) {
        guard NSApp.keyWindow?.makeFirstResponder(nil) == true else {
            error = "Finish editing the date and time before reviewing."
            return
        }
        DispatchQueue.main.async {
            guard !presentation.acceptedWork else { return }
            buildPlan(skip: skip)
        }
    }

    static func interruptionSummary(_ preview: InterruptionReview, zone: TimeZone) -> String {
        let action = preview.requestedEnd == nil ? "Discard" : "Save & Stop"
        let start = EntryDisclosure.bound(preview.entry.startAt, zone: zone)
        let checkpoint = EntryDisclosure.bound(preview.active.checkpointAt, zone: zone)
        let checkpointDuration = preview.active.checkpointAt - preview.entry.startAt
        var text =
            "\(action) interrupted entry on \(preview.path.text). Never resume automatically. "
            + "Start: \(start). Saved durable checkpoint: \(checkpoint). "
            + "Checkpointed duration: \(EntryDisclosure.durationText(checkpointDuration)). "
        guard let requestedEnd = preview.requestedEnd else {
            return text + """
                Explicit discard removes the interrupted entry, including all its checkpointed time. \
                No time is saved; no end is inferred.
                """
        }
        let end = EntryDisclosure.bound(requestedEnd, zone: zone)
        let duration = EntryDisclosure.durationText(requestedEnd - preview.entry.startAt)
        text += "Reviewed end: \(end). "
        if requestedEnd < preview.active.checkpointAt {
            text += """
                This earlier end removes some already-checkpointed time, even if \
                the displayed minute is the same.
                """
        }
        return text + "Saved duration: \(duration)."
    }

    private func buildPlan(skip: Bool) {
        guard let snapshot = model.snapshot else { return }
        do {
            if let row = pending.first(where: { $0.id == selectedPending }) {
                if skip {
                    let preview = try SleepPlanner.skip(row, in: snapshot)
                    command = .skip(preview)
                    inclusion = nil
                    summary = skipSummary(preview, row: row)
                } else {
                    let chosen = row.wakeAt == nil ? try end?.resolve(calendar: calendar) : nil
                    let preview = try SleepPlanner.include(row, endAt: chosen, in: snapshot)
                    command = .include(preview)
                    inclusion = preview.correction
                    summary = "Include pending interval: \(preview.path.text)"
                }
            } else if interrupted {
                let preview: InterruptionReview
                if skip {
                    preview = try SleepPlanner.interruption(endAt: nil, in: snapshot)
                } else {
                    preview = try Self.saveAndStop(end: end, calendar: calendar, in: snapshot)
                }
                command = .resolveInterruption(preview)
                inclusion = preview.correction
                summary = Self.interruptionSummary(preview, zone: zone)
            } else {
                throw EditorError.invalid("Select a current review item.")
            }
            stale = false
            error = nil
        } catch {
            self.error = String(describing: error)
            stale = true
        }
    }
    private func skipSummary(_ preview: SleepSkipPreview, row: PendingSleepInterval) -> String {
        let sleep = EntryDisclosure.bound(row.sleepAt, zone: zone)
        let wake =
            row.wakeAt.map {
                "Saved wake: \(EntryDisclosure.bound($0, zone: zone))."
            } ?? "End remains unknown."
        return "Skip unbilled interval on \(preview.path.text); no time will be added. "
            + "Sleep: \(sleep). " + wake
    }

    private func confirm() {
        guard let command, !stale, inclusion?.runningConflict == nil, presentation.begin(token) else { return }
        let result = model.enqueueTimeReview(command)
        Task { @MainActor in
            do {
                _ = try await result.value
                // Keep this one sheet open; refresh rows only from the published success.
                presentation.completeReview(token)
                self.command = nil
                inclusion = nil
                summary = nil
                selectedPending = interrupted ? nil : pending.first?.id
                resetEnd()
            } catch {
                self.error = String(describing: error)
                stale = true
                presentation.complete(token, error: error)
            }
        }
    }
}

extension TimeReviewView {
    static func saveAndStop(
        end: LocalCorrectionTime?,
        calendar: Calendar,
        in snapshot: LibrarySnapshot,
    ) throws -> InterruptionReview {
        guard let chosen = try end?.resolve(calendar: calendar) else {
            throw EditorError.invalid("Choose an explicit interruption end.")
        }
        let preview = try SleepPlanner.interruption(endAt: chosen, in: snapshot)
        guard chosen > preview.entry.startAt else {
            throw EditorError.invalid(
                """
                Save & Stop requires an end after Start. Use explicit discard to remove \
                the interrupted entry and its checkpointed time.
                """)
        }
        return preview
    }

}
