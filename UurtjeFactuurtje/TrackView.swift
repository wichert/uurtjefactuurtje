import SwiftUI
import LibraryStore

struct TrackView: View {
    @Bindable var presentation: TrackPresentation
    @FocusState private var listFocused: Bool
    private var model: WorkspaceModel { presentation.workspace }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let count = model.snapshot?.pendingSleepIntervals.count, count > 0 {
                HStack {
                    Text("\(count) pending sleep interval(s) — unbilled")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Review pending time…") { presentation.reviewTime() }
                }
                .accessibilityElement(children: .contain)
            }
            HStack {
                Picker("Project", selection: $presentation.selectedProjectID) {
                    Text("Select project").tag(UUID?.none)
                    ForEach(presentation.projects) {
                        Text($0.name + ($0.isArchived ? " (archived)" : "")).tag(Optional($0.id))
                    }
                }
                .frame(maxWidth: 300)
                Toggle("Show archived", isOn: $presentation.showArchived)
            }
            TextField("Search full project / task path", text: $presentation.search)
            HStack {
                Button("New project") { presentation.editProject() }
                if let project = presentation.projects.first(where: { $0.id == presentation.selectedProjectID }) {
                    Button("Edit project") { presentation.editProject(project.id) }
                    Button("New task") { presentation.newTask(projectID: project.id) }.disabled(project.isArchived)
                }
                Button("Add time") { presentation.addTime(taskID: presentation.selectedTaskID) }
                Button("Review time") { presentation.reviewTime() }
            }
            if model.snapshot?.projects.isEmpty == true {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Create your first project", systemImage: "folder").font(.headline)
                    Text("Use New project above, then create a leaf task. Selection alone never starts tracking.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            GeometryReader { geometry in
                VStack(alignment: .leading, spacing: 8) {
                    ScrollViewReader { scroll in
                        List(selection: $presentation.selectedTaskID) {
                    if let project = presentation.projects.first(where: { $0.id == presentation.selectedProjectID }) {
                        Section("Tasks") {
                            ForEach(presentation.rows(projectID: project.id)) { row in
                                HStack {
                                    if !row.isLeaf {
                                        Button {
                                            if !presentation.expandedTaskIDs.insert(row.id).inserted {
                                                presentation.expandedTaskIDs.remove(row.id)
                                            }
                                        } label: {
                                            Image(systemName: presentation.expandedTaskIDs.contains(row.id) || !presentation.search.isEmpty ? "chevron.down" : "chevron.right")
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("Toggle children of \(row.path)")
                                    }
                                    Text(row.path).lineLimit(2).help(row.path)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if !row.isLeaf {
                                        Text("Parent — not startable").foregroundStyle(.secondary)
                                    } else {
                                        Button("Start") { presentation.timer(.start(taskID: row.id)) }
                                            .disabled(!presentation.eligible(row.id) || model.isBusy)
                                    }
                                    Button("Edit") { presentation.editTask(row.id) }
                                }
                                .padding(.leading, CGFloat(min(row.depth, 3)) * 16)
                                .tag(row.id).id(row.id)
                                .accessibilityElement(children: .contain).accessibilityLabel(row.path)
                                .contextMenu {
                                    Button("New subtask") { presentation.newTask(projectID: project.id, parentID: row.id) }.disabled(project.isArchived)
                                    Button("Add time") { presentation.addTime(taskID: row.id) }.disabled(!row.isLeaf || project.isArchived)
                                    Button("Reveal path") { presentation.revealTask(row.id) }
                                }
                            }
                        }
                    }
                }
                .focused($listFocused)
                .onKeyPress(.return) {
                    guard let id = presentation.selectedTaskID,
                          presentation.canStartFromList(id, listFocused: listFocused), !model.isBusy else { return .ignored }
                    presentation.timer(.start(taskID: id)); return .handled
                }
                .onChange(of: presentation.reveal?.id, initial: true) { _, _ in reveal(scroll) }
                .onChange(of: presentation.sheet?.id) { _, new in if new == nil { reveal(scroll) } }
                    }
                    .frame(height: max(100, geometry.size.height * 0.45))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in timerStrip }
                            budgets
                            recent
                            today
                            undo
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding()
    }
    private func reveal(_ scroll: ScrollViewProxy) {
        guard let request = presentation.consumeReveal() else { return }
        // Only an explicit reveal moves focus; publications and warnings do not.
        scroll.scrollTo(request.taskID); listFocused = true
    }
    @ViewBuilder private var timerStrip: some View {
        if let active = model.snapshot?.activeTimer,
           let row = model.snapshot?.entries.first(where: { $0.id == active.entryID }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(presentation.path(row.taskID)).font(.headline)
                        .lineLimit(2).help(presentation.path(row.taskID))
                        .accessibilityLabel(presentation.path(row.taskID))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let stop = presentation.ownedStop {
                        Button("Stop") { presentation.timer(stop) }.disabled(model.isBusy)
                    } else {
                        Button("Review interruption") { presentation.reviewTime() }
                    }
                    Button("Reveal running task") { presentation.revealTask(row.taskID) }
                }
                switch Result(catching: { try model.timerElapsedSeconds() }) {
                case .success(let seconds):
                    Text(seconds.map { "\($0) seconds — provisional / checkpoint-bounded" } ?? "No active elapsed time")
                case .failure(let error): Text(String(describing: error)).textSelection(.enabled)
                }
                DisclosureGroup("Timer details") {
                    Text(String(describing: model.timerStatus)).textSelection(.enabled)
                    Text("Saved checkpoint: \(active.checkpointAt)").textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .contain)
        } else {
            Text("No running timer. Pending sleep is never included in elapsed time.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private var budgets: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let snapshot = model.snapshot {
                switch Result(catching: {
                    (try model.budgetUsage(), try BudgetRules.allocations(in: snapshot))
                }) {
                case .success(let projection):
                    let usage = projection.0
                    let allocations = projection.1.filter { item in
                        snapshot.tasks.contains { $0.id == item.taskID && $0.projectID == presentation.selectedProjectID }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if !allocations.isEmpty {
                            Text("Lifetime use includes descendants; open use is provisional when safe, otherwise checkpoint-bounded. Pending sleep is excluded. Allocation reserves budgets, not time used.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(allocations, id: \.taskID) { item in
                            let used = usage[item.taskID] ?? 0
                            let band = BudgetRules.band(used: used, budget: item.limitSeconds)
                            let ratio = min(Decimal(1), max(Decimal.zero, used / Decimal(item.limitSeconds)))
                            let difference = Decimal(item.limitSeconds) - used
                            let balance = difference < 0
                                ? "\(RateInput.text(-difference)) seconds over budget"
                                : "\(RateInput.text(difference)) seconds remaining"
                            let exact = "\(RateInput.text(used)) / \(item.limitSeconds) seconds used; \(balance)"
                            VStack(alignment: .leading, spacing: 4) {
                                Text(presentation.path(item.taskID)).font(.headline)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Text("\(ReportFormatting.budgetHours(seconds: used)) / \(ReportFormatting.budgetHours(seconds: Decimal(item.limitSeconds))) used — \(ReportFormatting.budgetBalance(used: used, budget: item.limitSeconds))")
                                    .monospacedDigit().help(exact)
                                    .accessibilityLabel("Lifetime usage").accessibilityValue(exact)
                                    .fixedSize(horizontal: false, vertical: true)
                                ProgressView(value: NSDecimalNumber(decimal: ratio).doubleValue)
                                    .accessibilityLabel("Lifetime budget progress").accessibilityValue(exact)
                                if band != .none {
                                    Text(band == .hundred ? "100% reached — tracking may continue" : "80% reached — tracking may continue")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if snapshot.tasks.contains(where: { $0.parentTaskID == item.taskID }) {
                                    Text(ReportFormatting.budgetAllocation(allocated: item.allocatedSeconds, budget: item.limitSeconds))
                                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                                        .help("\(RateInput.text(item.allocatedSeconds)) / \(item.limitSeconds) seconds allocated")
                                        .accessibilityLabel("Descendant frontier allocation")
                                        .accessibilityValue("\(RateInput.text(item.allocatedSeconds)) of \(item.limitSeconds) seconds allocated; \(RateInput.text(Decimal(item.limitSeconds) - item.allocatedSeconds)) seconds unallocated")
                                }
                            }
                        }
                    }
                case .failure(let error):
                    Text("Budget projection failed: \(String(describing: error))").textSelection(.enabled)
                }
            }
        }
    }
    private var recent: some View {
        let entries = (model.snapshot?.entries ?? []).sorted { $0.startAt > $1.startAt }
        var seen = Set<UUID>()
        let ids = entries.compactMap { seen.insert($0.taskID).inserted && presentation.eligible($0.taskID) ? $0.taskID : nil }.prefix(8)
        return GroupBox("Recent tasks (explicit Start only)") {
            ForEach(Array(ids), id: \.self) { id in
                HStack { Button(presentation.path(id)) { presentation.revealTask(id) }.help(presentation.path(id)); Button("Start") { presentation.timer(.start(taskID: id)) }.disabled(model.isBusy) }
            }
        }
    }
    @ViewBuilder private var today: some View {
        if let s = model.snapshot {
            GroupBox("Today — local calendar intersections; editing opens the whole saved entry") {
                ForEach(TrackPresentation.todayEntries(in: s, now: Date(), calendar: .current)) { row in
                    HStack {
                        EntryDisclosure(entry: row, path: presentation.path(row.taskID), zone: .current)
                        if row.endAt != nil { Button("Edit whole entry") { presentation.editTime(entryID: row.id) } }
                        else if let stop = presentation.ownedStop { Button("Stop") { presentation.timer(stop) } }
                        else { Button("Review") { presentation.reviewTime() } }
                    }
                }
            }
        }
    }
    private var undo: some View {
        HStack {
            switch model.migrationUndoAvailability {
            case .available(let receiptID): Button("Undo first-child migration") { presentation.undoMigration(receiptID: receiptID) }.disabled(model.isBusy)
            case .unavailable(let reason): Text("Migration Undo unavailable: \(reason)").textSelection(.enabled)
            }
            Button("Undo time correction") { presentation.undoCorrection() }.disabled(model.isBusy || !model.canUndoCorrection)
            Button("Undo time review") { presentation.undoTimeReview() }.disabled(model.isBusy || !model.canUndoTimeReview)
        }
    }
}
