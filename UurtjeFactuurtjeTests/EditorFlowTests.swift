import Foundation
import Testing
import LibraryStore
@testable import UurtjeFactuurtje

@Suite @MainActor struct EditorFlowTests {
    @Test func exactLocalizedRatesRejectRoundingAndPartialConsumption() throws {
        let us = Locale(identifier: "en_US"), nl = Locale(identifier: "nl_NL")
        for locale in [us, nl] {
            let sep = locale.decimalSeparator!
            #expect(RateInput.parse(" 0 ", locale: locale) == 0)
            #expect(RateInput.parse("123\(sep)456789", locale: locale) == Decimal(string: "123.456789"))
            let boundary = "12345678901234567890123456789012345678"
            let exact = try #require(Decimal(string: boundary, locale: us))
            #expect(RateInput.parse(boundary, locale: locale) == exact)
            #expect(RateInput.parse(boundary + "901", locale: locale) == nil)
            #expect(RateInput.parse(String(repeating: "9", count: 200), locale: locale) == nil)
            for bad in ["", "-1", "NaN", "1e3", "12junk", "12\(sep)", "\(sep)5", "1\(sep)2\(sep)3", "1 000", "1,000.00", "1.000,00"] {
                #expect(RateInput.parse(bad, locale: locale) == nil)
            }
            #expect(BudgetInput.parseHours("1\(sep)5", locale: locale) == 5400)
            #expect(BudgetInput.parseHours("1\(sep)5junk", locale: locale) == nil)
        }
    }
    @Test func unchangedBudgetAndLocationConsent() {
        var d = TaskDraft(id: UUID(), isNew: false, observedRevision: 4, projectID: UUID(), parentID: nil,
            name: "Draft", migrationAccepted: true, budgetEnabled: true, budgetHours: "rounded display",
            originalBudgetSeconds: 1, originalBudgetText: "rounded display")
        #expect(d.parsedBudget == 1)
        d.budgetHours = "not hours"; #expect(d.parsedBudget == nil)
        d.budgetEnabled = false; #expect(d.parsedBudget == nil)
        d.relocate(projectID: d.projectID, parentID: UUID()); #expect(!d.migrationAccepted)
        let request = d.request(start: true)
        #expect(request.id == d.id); #expect(request.start); #expect(!request.confirmMigration)
    }
    @Test func suspendedDraftRestoresOnSaveAndCancel() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), root = try await task(t, project: p, name: "Root")
            let leaf = try await task(t, project: p, parent: root, name: "Leaf")
            t.editTask(leaf)
            guard case .task(var draft) = t.sheet else { Issue.record("Missing task"); return }
            draft.name = "Unsent name"; draft.budgetHours = "17.5"; t.updateTaskDraft(draft)
            let s = try #require(t.workspace.snapshot)
            _ = try BudgetRules.allowance(in: s, projectID: p, parentTaskID: root, editingTaskID: leaf)
            _ = try BudgetRules.allocations(in: s)
            t.editConstrainingBudget(taskID: root)
            #expect(t.suspendedTaskDraft?.name == "Unsent name")
            t.editConstrainingBudget(taskID: leaf); #expect(t.suspendedTaskDraft?.id == leaf)
            t.cancelSheet()
            guard case .task(let restored) = t.sheet else { Issue.record("Not restored"); return }
            #expect(restored.name == "Unsent name"); #expect(restored.budgetHours == "17.5")
            t.editConstrainingBudget(taskID: root); let token = t.routeToken
            #expect(t.begin(token)); t.complete(token)
            guard case .task(let saved) = t.sheet else { Issue.record("Not restored after save"); return }
            #expect(saved.id == leaf); #expect(t.suspendedTaskDraft == nil)
        }
    }
    @Test func migrationRevisionConsentAndCommittedStart() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), parent = try await task(t, project: p)
            let before = try #require(t.workspace.snapshot)
            let preview = try CorrectionPlanner.preview(.add(id: UUID(), taskID: parent, startAt: 100, endAt: 200), in: before)
            _ = try await t.workspace.enqueueCorrection(.apply(preview)).value
            let s = try #require(t.workspace.snapshot), child = UUID()
            do {
                _ = try await t.workspace.enqueueTaskCreation(TaskCreationRequest(id: child, projectID: p, parentID: parent, name: "New", confirmMigration: false, start: false), expectedRevision: s.revision).value
                Issue.record("Unconfirmed migration succeeded")
            } catch { #expect(t.workspace.snapshot == s) }
            let result = try await t.workspace.enqueueTaskCreation(TaskCreationRequest(id: child, projectID: p, parentID: parent, name: "New", confirmMigration: true, start: false), expectedRevision: s.revision).value
            #expect(result.movedEntryCount == 1); #expect(result.genericID != nil)
            guard case .available(let receiptID) = t.workspace.migrationUndoAvailability else { Issue.record("Missing guarded receipt"); return }
            _ = try await t.workspace.enqueueMigrationUndo(receiptID: receiptID).value
            #expect(t.workspace.snapshot?.tasks.contains(where: { $0.id == child }) == false)
            do {
                _ = try await t.workspace.enqueueTaskCreation(TaskCreationRequest(id: UUID(), projectID: p, parentID: nil, name: "Stale", confirmMigration: false, start: true), expectedRevision: s.revision).value
                Issue.record("Stale request succeeded")
            } catch { #expect(t.workspace.snapshot?.activeTimer == nil) }
            let current = try #require(t.workspace.snapshot)
            let running = UUID()
            let accepted = t.workspace.enqueueTaskCreation(TaskCreationRequest(id: running, projectID: p, parentID: nil, name: "Start", confirmMigration: false, start: true), expectedRevision: current.revision)
            #expect(t.workspace.snapshot == current)
            let committed = try await accepted.value
            #expect(committed.snapshot.activeTimer != nil)
            #expect(committed.snapshot.tasks.first(where: { $0.id == running })?.budgetSeconds == nil)
            _ = try await t.workspace.enqueueTimer(.stop(expectedEntryID: committed.snapshot.activeTimer?.entryID)).value
        }
    }
    @Test func currencyConfirmationAndArchiveRetention() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), leaf = try await task(t, project: p)
            let s = try #require(t.workspace.snapshot)
            let preview = try CorrectionPlanner.preview(.add(id: UUID(), taskID: leaf, startAt: 100, endAt: 200), in: s)
            _ = try await t.workspace.enqueueCorrection(.apply(preview)).value
            let before = try #require(t.workspace.snapshot)
            do {
                _ = try await t.workspace.submit(.updateProject(id: p, name: "Project", rate: 1, currency: "USD", confirmedPreviousCurrency: nil), expectedRevision: before.revision)
                Issue.record("Missing currency consent accepted")
            } catch { #expect(t.workspace.snapshot == before) }
            _ = try await t.workspace.submit(.updateProject(id: p, name: "Project", rate: 1, currency: "USD", confirmedPreviousCurrency: "EUR"), expectedRevision: before.revision)
            t.editProject(p)
            guard case .project(let draft) = t.sheet else { Issue.record("Missing draft"); return }
            #expect(!draft.archiveConfirmed); #expect(draft.confirmedPreviousCurrency == nil)
            t.cancelSheet()
            let current = try #require(t.workspace.snapshot)
            _ = try await t.workspace.submit(.setArchived(id: p, archived: true), expectedRevision: current.revision)
            #expect(t.workspace.snapshot?.entries == before.entries)
        }
    }
    @Test func dstChoiceStableIDsPreviewBackAndStaleDisclosure() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), leaf = try await task(t, project: p)
            let s = try #require(t.workspace.snapshot)
            let f = try CorrectionForm(route: CorrectionRoute(id: UUID(), mode: .add(taskID: leaf)), snapshot: s, now: Date(timeIntervalSince1970: 1_800_000_000))
            f.timeZone = try #require(TimeZone(identifier: "Europe/Amsterdam"))
            f.start = LocalCorrectionTime(components: DateComponents(year: 2025, month: 10, day: 26, hour: 2, minute: 30, second: 0))
            guard case .ambiguous(let earlier, let later, _, _) = CorrectionClock.resolve(f.start.components, calendar: f.calendar) else { Issue.record("Expected overlap"); return }
            #expect(throws: (any Error).self) { try f.start.resolve(calendar: f.calendar) }
            f.start.select(earlier); f.end = CorrectionForm.fields(Date(timeIntervalSince1970: TimeInterval(later + 3600)), calendar: f.calendar)
            // The chosen end is unambiguous; the repeated start requires the explicit choice above.
            try f.review(in: s); let id = f.entryID
            let preview = try #require(f.preview); #expect(preview.targetPath.text == "Project / Task")
            f.invalidateConfirmation(); #expect(f.confirmationIsStale); #expect(f.preview == preview)
            f.back(); #expect(f.preview == nil); #expect(f.entryID == id)
            try f.review(in: s)
            _ = try await t.workspace.enqueueCorrection(.apply(try #require(f.preview))).value
            #expect(t.workspace.canUndoCorrection)
            _ = try await t.workspace.enqueueCorrection(.undo).value
            #expect(!t.workspace.canUndoCorrection); #expect(!t.workspace.canUndoTimeReview)
        }
    }
    @Test func pendingOnlyReviewRequiresExplicitEndAndSkipUndo() throws {
        let p = Project(id: UUID(), name: "Project", hourlyRate: 0, currencyCode: "EUR")
        let owner = TaskRecord(id: UUID(), projectID: p.id, name: "Leaf")
        let pending = PendingSleepInterval(id: UUID(), taskID: owner.id, sleepAt: 100, wakeAt: nil)
        let s = LibrarySnapshot(schemaVersion: 1, revision: 0, projects: [p], tasks: [owner], entries: [], activeTimer: nil, pendingSleepIntervals: [pending])
        #expect(throws: (any Error).self) { try SleepPlanner.include(pending, endAt: nil, in: s) }
        let included = try SleepPlanner.include(pending, endAt: 200, in: s)
        #expect(included.pending == pending); #expect(included.path.text == "Project / Leaf")
        let skipped = try SleepPlanner.skip(pending, in: s); #expect(skipped.pending == pending)
        let entry = TimeEntry(id: UUID(), taskID: owner.id, startAt: 10, endAt: nil)
        let active = ActiveTimer(entryID: entry.id, checkpointAt: 90)
        let interrupted = LibrarySnapshot(schemaVersion: 1, revision: 0, projects: [p], tasks: [owner], entries: [entry], activeTimer: active, pendingSleepIntervals: [])
        #expect(try SleepPlanner.interruption(endAt: 90, in: interrupted).requestedEnd == 90)
        #expect(try SleepPlanner.interruption(endAt: nil, in: interrupted).correction == nil)
    }
}
