import SwiftUI
import LibraryStore

struct TrackView: View {
    @Bindable var presentation: TrackPresentation
    @FocusState private var listFocused: Bool
    private var model: WorkspaceModel { presentation.workspace }
    var body: some View {
        VStack(alignment: .leading) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in timerStrip }
            HStack {
                Picker("Project", selection: $presentation.selectedProjectID) {
                    Text("Select project").tag(UUID?.none)
                    ForEach(presentation.projects) { Text($0.name + ($0.isArchived ? " (archived)" : "")).tag(Optional($0.id)) }
                }
                Toggle("Show archived", isOn: $presentation.showArchived)
                TextField("Search full project / task path", text: $presentation.search)
            }
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
                ContentUnavailableView("Create your first project", systemImage: "folder", description: Text("Then create a leaf task. Selection alone never starts tracking."))
            }
            ScrollViewReader { scroll in
                List(selection: $presentation.selectedTaskID) {
                    if let project = presentation.projects.first(where: { $0.id == presentation.selectedProjectID }) {
                        ForEach(presentation.rows(projectID: project.id)) { row in
                            HStack {
                                if !row.isLeaf {
                                    Button {
                                        if !presentation.expandedTaskIDs.insert(row.id).inserted { presentation.expandedTaskIDs.remove(row.id) }
                                    } label: { Image(systemName: presentation.expandedTaskIDs.contains(row.id) || !presentation.search.isEmpty ? "chevron.down" : "chevron.right") }
                                        .buttonStyle(.borderless).accessibilityLabel("Toggle children of \(row.path)")
                                }
                                Text(row.task.name).help(row.path)
                                Spacer()
                                if !row.isLeaf { Text("Parent — not startable").foregroundStyle(.secondary) }
                                else { Button("Start") { presentation.timer(.start(taskID: row.id)) }.disabled(!presentation.eligible(row.id) || model.isBusy) }
                                Button("Edit") { presentation.editTask(row.id) }
                            }.padding(.leading, CGFloat(row.depth) * 16).tag(row.id).id(row.id)
                            .accessibilityElement(children: .contain).accessibilityLabel(row.path)
                            .contextMenu {
                                Button("New subtask") { presentation.newTask(projectID: project.id, parentID: row.id) }.disabled(project.isArchived)
                                Button("Add time") { presentation.addTime(taskID: row.id) }.disabled(!row.isLeaf || project.isArchived)
                                Button("Reveal path") { presentation.revealTask(row.id) }
                            }
                        }
                    }
                }.focused($listFocused)
                .onKeyPress(.return) {
                    guard let id = presentation.selectedTaskID, presentation.canStartFromList(id, listFocused: listFocused), !model.isBusy else { return .ignored }
                    presentation.timer(.start(taskID: id)); return .handled
                }
                .onChange(of: presentation.reveal?.id) { _, _ in reveal(scroll) }
                .onChange(of: presentation.sheet?.id) { _, new in if new == nil { reveal(scroll) } }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    budgets
                    recent
                    today
                    undo
                }
            }.frame(maxHeight: 280)
        }.padding()
    }
    private func reveal(_ scroll: ScrollViewProxy) {
        guard presentation.sheet == nil, let request = presentation.reveal else { return }
        // Only an explicit reveal moves focus; publications and warnings do not.
        scroll.scrollTo(request.taskID); listFocused = true
    }
    @ViewBuilder private var timerStrip: some View {
        if let active = model.snapshot?.activeTimer, let row = model.snapshot?.entries.first(where: { $0.id == active.entryID }) {
            HStack {
                Text(presentation.path(row.taskID)).font(.headline)
                Text(String(describing: model.timerStatus))
                switch Result(catching: { try model.timerElapsedSeconds() }) {
                case .success(let seconds): Text(seconds.map { "\($0) seconds — provisional / checkpoint-bounded" } ?? "No active elapsed time")
                case .failure(let error): Text(String(describing: error)).textSelection(.enabled)
                }
                Text("Saved checkpoint: \(active.checkpointAt)").textSelection(.enabled)
                if let stop = presentation.ownedStop { Button("Stop") { presentation.timer(stop) }.disabled(model.isBusy) }
                else { Button("Review interruption") { presentation.reviewTime() } }
                Button("Reveal running task") { presentation.revealTask(row.taskID) }
            }.accessibilityElement(children: .contain)
        } else { Text("No running timer. Pending sleep is never included in elapsed time.") }
    }
    @ViewBuilder private var budgets: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            switch Result(catching: { try model.budgetUsage() }) {
            case .success(let usage):
                ForEach((model.snapshot?.tasks ?? []).filter { $0.projectID == presentation.selectedProjectID && $0.budgetSeconds != nil }) { task in
                    if let budget = task.budgetSeconds {
                        let used = usage[task.id] ?? 0
                        let band = BudgetRules.band(used: used, budget: budget)
                        VStack(alignment: .leading) {
                            Text("\(presentation.path(task.id)) — lifetime \(used.description) / \(budget) seconds; band \(band.rawValue)%\(used > Decimal(budget) ? "; overrun" : ""); open use provisional, otherwise checkpoint")
                            ProgressView(value: min(1, max(0, NSDecimalNumber(decimal: used / Decimal(budget)).doubleValue)))
                                .accessibilityLabel("Lifetime budget for \(presentation.path(task.id))").accessibilityValue("\(used.description) of \(budget) seconds")
                        }
                    }
                }
            case .failure(let error): Text("Budget projection failed: \(String(describing: error))").textSelection(.enabled)
            }
        }
    }
    private var recent: some View {
        let entries = (model.snapshot?.entries ?? []).sorted { $0.startAt > $1.startAt }
        var seen = Set<UUID>()
        let ids = entries.compactMap { seen.insert($0.taskID).inserted && presentation.eligible($0.taskID) ? $0.taskID : nil }.prefix(8)
        return GroupBox("Recent tasks (explicit Start only)") {
            ForEach(Array(ids), id: \.self) { id in
                HStack { Button(presentation.path(id)) { presentation.revealTask(id) }; Button("Start") { presentation.timer(.start(taskID: id)) }.disabled(model.isBusy) }
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
