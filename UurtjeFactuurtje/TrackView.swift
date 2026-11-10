import SwiftUI
import LibraryStore

struct TrackView: View {
    @Bindable var presentation: TrackPresentation
    let openReport: (UUID, UUID?) -> Void
    @FocusState private var tableFocused: Bool
    @State private var mountedRows: Set<TrackRowID> = []
    private var model: WorkspaceModel { presentation.workspace }



    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let count = model.snapshot?.pendingSleepIntervals.count, count > 0 {
                HStack {
                    Text("\(count) pending sleep interval(s) — unbilled")
                    Spacer()
                    Button("Review pending time…") { presentation.reviewTime() }
                }
            }
            HStack {
                Button("New project") { presentation.editProject() }
                Button("New task") { newTask() }.disabled(!canCreateTask)
                Toggle("Show archived", isOn: $presentation.showArchived)
                TextField("Search full project / task path", text: $presentation.search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search full project or task path")
            }
            if model.snapshot?.projects.isEmpty == true {
                Text("Create your first project, then create a leaf task. Selection alone never starts tracking.")
                    .foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let totals = Result { try presentation.projectTaskTotals() }
                VStack(alignment: .leading, spacing: 8) {
                    ScrollViewReader { scroll in
                        let outline = presentation.outlineRows()
                        Table(of: TrackOutlineRow.self, selection: $presentation.selectedRow) {
                            TableColumn("Title") { row in
                                Text(row.title + (row.isArchived ? " (archived)" : ""))
                                    .lineLimit(2).help(row.path).accessibilityLabel(row.path)
                                    .id(row.id)
                                    .onAppear {
                                        mountedRows.insert(row.id)
                                        reveal(scroll)
                                    }
                                    .onDisappear { mountedRows.remove(row.id) }
                            }
                            TableColumn("Total time") { row in
                                switch totals {
                                case .success(let values):
                                    Text(ReportFormatting.totalTime(seconds: values[row.id, default: 0]))
                                        .monospacedDigit()
                                case .failure:
                                    Text("Unavailable").foregroundStyle(.secondary)
                                }
                            }
                            TableColumn("Actions") { row in
                                HStack {
                                    if case .task(let id) = row.id, row.isLeafTask {
                                        Button("Start") { presentation.timer(.start(taskID: id)) }
                                            .disabled(row.isArchived || model.isBusy)
                                            .accessibilityLabel("Start \(row.path)")
                                    }
                                    Button("Edit") { edit(row.id) }
                                        .accessibilityLabel("Edit \(row.path)")
                                    Button("Report") { report(row) }
                                        .accessibilityLabel("Report for \(row.path)")
                                }
                            }
                        } rows: {
                            TrackHierarchyRows(nodes: outline, presentation: presentation)
                        }
                        .focused($tableFocused)
                        .onKeyPress(.return) {
                            guard case .task(let id) = presentation.selectedRow,
                                  tableFocused, presentation.isVisible(.task(id)),
                                  presentation.eligible(id), !model.isBusy else { return .ignored }
                            presentation.timer(.start(taskID: id))
                            return .handled
                        }
                        .contextMenu(forSelectionType: TrackRowID.self) { selected in
                            if let id = selected.first { contextActions(id) }
                        }
                        .onChange(of: presentation.reveal?.id, initial: true) { _, _ in reveal(scroll) }
                        .onChange(of: outline) { _, _ in reveal(scroll) }
                        .onChange(of: presentation.sheet?.id) { _, new in if new == nil { reveal(scroll) } }
                    }
                    if case .failure(let error) = totals {
                        Text("Total time unavailable: \(String(describing: error))")
                            .foregroundStyle(.red).textSelection(.enabled)
                    }
                    timerStrip
                }
            }
            DisclosureGroup("Budget details") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        budgets
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .padding()
        .toolbar { TrackControlCommands(presentation: presentation) }
    }

    private var canCreateTask: Bool {
        guard let row = presentation.selectedRow, presentation.isVisible(row),
              let id = presentation.selectedProjectID,
              let project = presentation.projects.first(where: { $0.id == id }) else { return false }
        return !project.isArchived
    }
    private func newTask() {
        guard canCreateTask, let projectID = presentation.selectedProjectID else { return }
        presentation.newTask(projectID: projectID, parentID: presentation.selectedTaskID)
    }
    private func edit(_ id: TrackRowID) {
        switch id {
        case .project(let id): presentation.editProject(id)
        case .task(let id): presentation.editTask(id)
        }
    }
    private func report(_ row: TrackOutlineRow) {
        switch row.id {
        case .project: openReport(row.projectID, nil)
        case .task(let id): openReport(row.projectID, id)
        }
    }
    @ViewBuilder private func contextActions(_ id: TrackRowID) -> some View {
        switch id {
        case .project(let projectID):
            Button("Edit project") { presentation.editProject(projectID) }
            Button("Project report") { openReport(projectID, nil) }
            if presentation.projects.contains(where: { $0.id == projectID && !$0.isArchived }) {
                Button("New task") { presentation.newTask(projectID: projectID) }
            }
        case .task(let taskID):
            if let task = model.snapshot?.tasks.first(where: { $0.id == taskID }) {
                Button("Edit task") { presentation.editTask(taskID) }
                Button("Task report") { openReport(task.projectID, taskID) }
                Button("New subtask") { presentation.newTask(projectID: task.projectID, parentID: taskID) }
                    .disabled(!presentation.projects.contains { $0.id == task.projectID && !$0.isArchived })
                Button("Add time") { presentation.addTime(taskID: taskID) }
                    .disabled(!presentation.eligible(taskID))
                Button("Reveal path") { presentation.revealTask(taskID) }
            }
        }
    }
    private func reveal(_ scroll: ScrollViewProxy) {
        guard presentation.destination == .track, presentation.sheet == nil,
              let request = presentation.reveal,
              presentation.selectedRow == .task(request.taskID) else { return }
        let target = TrackRowID.task(request.taskID)
        scroll.scrollTo(target)
        guard mountedRows.contains(target) else { return }
        tableFocused = true
        presentation.completeReveal(requestID: request.id)
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
                            let band = BudgetRules.band(used: used, budget: item.limitMinutes)
                            let ratio = min(Decimal(1), max(Decimal.zero, used / (Decimal(item.limitMinutes) * 60)))
                            let difference = Decimal(item.limitMinutes) * 60 - used
                            let balance = difference < 0
                                ? "\(RateInput.text(-difference)) seconds over budget"
                                : "\(RateInput.text(difference)) seconds remaining"
                            let exact = "\(RateInput.text(used)) / \(Decimal(item.limitMinutes) * 60) seconds used; \(balance)"
                            VStack(alignment: .leading, spacing: 4) {
                                Text(presentation.path(item.taskID)).font(.headline)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Text("\(ReportFormatting.budgetHours(seconds: used)) / \(ReportFormatting.budgetHours(seconds: Decimal(item.limitMinutes) * 60)) used — \(ReportFormatting.budgetBalance(used: used, budget: item.limitMinutes))")
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
                                    Text(ReportFormatting.budgetAllocation(allocated: item.allocatedMinutes, budget: item.limitMinutes))
                                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                                        .help("\(RateInput.text(item.allocatedMinutes)) minutes of \(item.limitMinutes) minutes allocated")
                                        .accessibilityLabel("Descendant frontier allocation")
                                        .accessibilityValue("\(RateInput.text(item.allocatedMinutes)) of \(item.limitMinutes) minutes allocated; \(RateInput.text(Decimal(item.limitMinutes) - item.allocatedMinutes)) minutes unallocated")
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
    private var undo: some View {
        HStack {
            switch model.migrationUndoAvailability {
            case .available(let receiptID):
                Button("Undo first-child migration") { presentation.undoMigration(receiptID: receiptID) }.disabled(model.isBusy)
            case .unavailable(let reason):
                Text("Migration Undo unavailable: \(reason)").textSelection(.enabled)
            }
            Button("Undo time correction") { presentation.undoCorrection() }.disabled(model.isBusy || !model.canUndoCorrection)
            Button("Undo time review") { presentation.undoTimeReview() }.disabled(model.isBusy || !model.canUndoTimeReview)
        }
    }
}

private struct TrackHierarchyRows: TableRowContent {
    let nodes: [TrackOutlineRow]
    let presentation: TrackPresentation
    @TableRowBuilder<TrackOutlineRow> var tableRowBody: some TableRowContent<TrackOutlineRow> {
        ForEach(nodes) { node in
            if node.children.isEmpty {
                TableRow(node)
            } else {
                DisclosureTableRow(node, isExpanded: expansion(node.id)) {
                    TrackHierarchyRows(nodes: node.children, presentation: presentation)
                }
            }
        }
    }
    private func expansion(_ id: TrackRowID) -> Binding<Bool> {
        Binding {
            if !presentation.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            switch id {
            case .project(let id): return presentation.expandedProjectIDs.contains(id)
            case .task(let id): return presentation.expandedTaskIDs.contains(id)
            }
        } set: { expanded in
            guard presentation.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            switch id {
            case .project(let id):
                if expanded { presentation.expandedProjectIDs.insert(id) }
                else { presentation.expandedProjectIDs.remove(id) }
            case .task(let id):
                if expanded { presentation.expandedTaskIDs.insert(id) }
                else { presentation.expandedTaskIDs.remove(id) }
            }
        }
    }
}


struct TrackControlCommands: ToolbarContent {
    @Bindable var presentation: TrackPresentation
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle("Show archived", isOn: $presentation.showArchived)
            Menu("Time and history") {
                Button("Undo time correction") { presentation.undoCorrection() }
                    .disabled(presentation.workspace.isBusy || !presentation.workspace.canUndoCorrection)
                Button("Undo time review") { presentation.undoTimeReview() }
                    .disabled(presentation.workspace.isBusy || !presentation.workspace.canUndoTimeReview)
                if case .available(let receiptID) = presentation.workspace.migrationUndoAvailability {
                    Button("Undo first-child migration") { presentation.undoMigration(receiptID: receiptID) }
                        .disabled(presentation.workspace.isBusy)
                }
            }
        }
    }
}
