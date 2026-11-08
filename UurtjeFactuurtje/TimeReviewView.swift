import SwiftUI
import LibraryStore

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
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c }
    private var pending: [PendingSleepInterval] {
        (model.snapshot?.pendingSleepIntervals ?? []).sorted { $0.sleepAt == $1.sleepAt ? $0.id.uuidString < $1.id.uuidString : $0.sleepAt < $1.sleepAt }
    }
    private var interrupted: Bool {
        switch model.timerStatus { case .paused, .reviewRequired: model.snapshot?.activeTimer != nil; default: false }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review unconfirmed time").font(.headline)
                Text("Pending sleep is not billed. Resolving an interruption stays stopped.")
                Picker("Review item", selection: $selectedPending) {
                    if interrupted { Text("Interrupted active entry").tag(UUID?.none) }
                    ForEach(pending) { row in Text("\(presentation.path(row.taskID)) — \(row.id)").tag(Optional(row.id)) }
                }
                if let row = pending.first(where: { $0.id == selectedPending }) {
                    Text(presentation.path(row.taskID)).textSelection(.enabled)
                    Text("Sleep: \(EntryDisclosure.bound(row.sleepAt, zone: zone))")
                    Text(row.wakeAt.map { "Exact wake: \(EntryDisclosure.bound($0, zone: zone))" } ?? "End unknown — enter an explicit end; nothing is inferred from now.")
                    if row.wakeAt == nil { endFields }
                    HStack {
                        Button("Review Include") { plan(skip: false) }
                        Button("Review Skip", role: .destructive) { plan(skip: true) }
                    }
                } else if interrupted, let active = model.snapshot?.activeTimer,
                          let entry = model.snapshot?.entries.first(where: { $0.id == active.entryID }) {
                    EntryDisclosure(entry: entry, path: presentation.path(entry.taskID), zone: zone)
                    Text("Durable checkpoint: \(EntryDisclosure.bound(active.checkpointAt, zone: zone))")
                    endFields
                    HStack {
                        Button("Review Save & Stop") { plan(skip: false) }
                        Button("Review explicit discard", role: .destructive) { plan(skip: true) }
                    }
                } else { Text("No selected review item. Choose a pending interval, or there is nothing to resolve.") }
                if let summary { Text(summary).textSelection(.enabled) }
                if let inclusion { AdjustmentDisclosure(preview: inclusion, zone: zone) }
                if stale { Text("Evidence changed or a submission failed. Review again; old disclosure is retained.") }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    Button("Cancel") { presentation.cancelSheet() }.keyboardShortcut(.cancelAction)
                    Button("Back") { command = nil; inclusion = nil; summary = nil; stale = false }
                    if inclusion?.runningConflict != nil, let stop = presentation.ownedStop {
                        Button("Stop, then review again") { presentation.timer(stop) { stale = true } }
                    }
                    Button("Confirm reviewed action") { confirm() }
                        .disabled(command == nil || stale || inclusion?.runningConflict != nil)
                }
            }.disabled(presentation.acceptedWork)
        }.padding().frame(minWidth: 580, idealHeight: 650)
        .onAppear { selectedPending = interrupted ? nil : pending.first?.id; resetEnd() }
        .onChange(of: selectedPending) { _, _ in command = nil; inclusion = nil; summary = nil; resetEnd() }
        .onChange(of: end) { _, _ in if command != nil { stale = true } }
        .onChange(of: model.snapshot?.revision) { _, _ in if command != nil { stale = true } }
    }
    @ViewBuilder private var endFields: some View {
        if end != nil {
            WallTimeFields(title: "Explicit end (frozen \(zone.identifier))", value: Binding(get: { end! }, set: { end = $0 }), calendar: calendar)
        } else {
            Button("Enter an explicit unknown end") {
                // Start with the boundary, not launch/now; equal bounds cannot accidentally include a gap.
                if let row = pending.first(where: { $0.id == selectedPending }) {
                    end = CorrectionForm.fields(Date(timeIntervalSince1970: TimeInterval(row.sleepAt)), calendar: calendar)
                }
            }
        }
    }
    private func resetEnd() {
        end = nil; stale = false
        if selectedPending == nil, interrupted, let checkpoint = model.snapshot?.activeTimer?.checkpointAt {
            end = CorrectionForm.fields(Date(timeIntervalSince1970: TimeInterval(checkpoint)), calendar: calendar)
        }
    }
    private func plan(skip: Bool) {
        guard let s = model.snapshot else { return }
        do {
            if let row = pending.first(where: { $0.id == selectedPending }) {
                if skip {
                    let preview = try SleepPlanner.skip(row, in: s); command = .skip(preview); inclusion = nil
                    summary = "Skip unbilled interval \(preview.pending.id) on \(preview.path.text); no time will be added."
                } else {
                    let chosen = row.wakeAt == nil ? try end?.resolve(calendar: calendar) : nil
                    let preview = try SleepPlanner.include(row, endAt: chosen, in: s)
                    command = .include(preview); inclusion = preview.correction
                    summary = "Include pending \(preview.pending.id): \(preview.path.text)"
                }
            } else if interrupted {
                let chosen = skip ? nil : try end?.resolve(calendar: calendar)
                if !skip && chosen == nil { throw EditorError.invalid("Choose an explicit interruption end.") }
                let preview = try SleepPlanner.interruption(endAt: chosen, in: s)
                command = .resolveInterruption(preview); inclusion = preview.correction
                summary = "\(skip ? "Discard" : "Save & Stop") interrupted entry \(preview.entry.id) on \(preview.path.text). Never resume automatically."
            } else { throw EditorError.invalid("Select a current review item.") }
            stale = false; error = nil
        } catch { self.error = String(describing: error); stale = true }
    }
    private func confirm() {
        guard let command, !stale, inclusion?.runningConflict == nil, presentation.begin(token) else { return }
        let result = model.enqueueTimeReview(command)
        Task { @MainActor in
            do {
                _ = try await result.value
                // Keep this one sheet open; refresh rows only from the published success.
                presentation.completeReview(token)
                self.command = nil; inclusion = nil; summary = nil
                selectedPending = interrupted ? nil : pending.first?.id; resetEnd()
            } catch { self.error = String(describing: error); stale = true; presentation.complete(token, error: error) }
        }
    }
}
