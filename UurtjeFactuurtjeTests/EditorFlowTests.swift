import Foundation
import Testing
@testable import LibraryStore
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
            #expect(BudgetInput.parseHours("1\(sep)5", locale: locale) == 90)
            #expect(BudgetInput.parseHours("1\(sep)5junk", locale: locale) == nil)
        }
    }
    @Test func unchangedBudgetAndLocationConsent() {
        var d = TaskDraft(id: UUID(), isNew: false, observedRevision: 4, projectID: UUID(), parentID: nil,
            name: "Draft", migrationAccepted: true, budgetEnabled: true, budgetHours: "rounded display",
            originalBudgetMinutes: 1, originalBudgetText: "rounded display")
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
            #expect(committed.snapshot.tasks.first(where: { $0.id == running })?.budgetMinutes == nil)
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
    @Test func nativeMinuteBindingPreservesOtherSavedBoundaryAndPersistsExactInstants() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), leaf = try await task(t, project: p)
            let utc = try #require(TimeZone(secondsFromGMT: 0))
            let id = UUID(), lo: Int64 = 1_700_000_017, hi: Int64 = 1_700_003_653
            let before = try #require(t.workspace.snapshot)
            let seed = try CorrectionPlanner.preview(.add(id: id, taskID: leaf, startAt: lo, endAt: hi), in: before)
            _ = try await t.workspace.enqueueCorrection(.apply(seed)).value
            let saved = try #require(t.workspace.snapshot)
            let f = try CorrectionForm(route: CorrectionRoute(id: UUID(), mode: .edit(entryID: id)),
                snapshot: saved, now: Date(), timeZone: utc)
            let startOnly = try CorrectionForm(route: CorrectionRoute(id: UUID(), mode: .edit(entryID: id)),
                snapshot: saved, now: Date(), timeZone: utc)
            startOnly.start = CorrectionForm.applyingPickerDate(
                CorrectionForm.pickerDate(for: startOnly.start).addingTimeInterval(60), to: startOnly.start)
            try startOnly.review(in: saved)
            switch try #require(startOnly.preview).draft {
            case .add(_, _, _, let stop), .edit(_, _, _, let stop): #expect(stop == hi)
            }
            #expect(try startOnly.end.resolve(calendar: startOnly.calendar) == hi)
            let originalStart = f.start, originalEnd = f.end
            let visibleStart = CorrectionForm.pickerDate(for: f.start)
            #expect(CorrectionForm.pickerCalendar.component(.second, from: visibleStart) == 0)
            #expect(f.start == originalStart)
            #expect(CorrectionForm.applyingPickerDate(visibleStart, to: f.start) == originalStart)
            #expect(CorrectionForm.applyingPickerDate(CorrectionForm.pickerDate(for: f.end), to: f.end) == originalEnd)
            try f.review(in: saved)
            #expect(try f.start.resolve(calendar: f.calendar) == lo)
            #expect(try f.end.resolve(calendar: f.calendar) == hi)
            f.back()
            f.end = CorrectionForm.applyingPickerDate(
                CorrectionForm.pickerDate(for: f.end).addingTimeInterval(60), to: f.end)
            let changedEnd = try f.end.resolve(calendar: f.calendar)
            #expect(f.end.components.second == 0)
            #expect(f.end.selectedInstant == nil)
            #expect(changedEnd == hi - hi % 60 + 60)
            #expect(try f.start.resolve(calendar: f.calendar) == lo)
            try f.review(in: saved)
            _ = try await t.workspace.enqueueCorrection(.apply(try #require(f.preview))).value
            let after = try #require(t.workspace.snapshot)
            let row = try #require(after.entries.first(where: { $0.id == id }))
            #expect(row.startAt == lo)
            #expect(row.endAt == changedEnd)
            let g = try CorrectionForm(route: CorrectionRoute(id: UUID(), mode: .edit(entryID: id)),
                snapshot: after, now: Date(), timeZone: utc)
            g.start = CorrectionForm.applyingPickerDate(
                CorrectionForm.pickerDate(for: g.start).addingTimeInterval(60), to: g.start)
            g.start = CorrectionForm.applyingPickerDate(visibleStart, to: g.start)
            #expect(g.start.components.second == 0)
            #expect(try g.start.resolve(calendar: g.calendar) == lo - lo % 60)
            #expect(try g.end.resolve(calendar: g.calendar) == changedEnd)
            try g.review(in: after)
            _ = try await t.workspace.enqueueCorrection(.apply(try #require(g.preview))).value
            let final = try #require(t.workspace.snapshot?.entries.first(where: { $0.id == id }))
            #expect(final.startAt == lo - lo % 60)
            #expect(final.endAt == changedEnd)
        }
    }

    @Test func correctionDisclosureHasMinuteValuesAndInformativeOffsetsOnly() throws {
        let zone = try #require(TimeZone(identifier: "Europe/Amsterdam"))
        var c = Calendar(identifier: .gregorian); c.timeZone = zone
        let date = try #require(c.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 57)))
        let instant = Int64(date.timeIntervalSince1970)
        #expect(EntryDisclosure.bound(instant, zone: zone) == "2026-01-02 03:04 — Europe/Amsterdam, UTC+01:00")
        #expect(EntryDisclosure.offset(20701) == "approximately UTC+05:45 (historical offset)")
        #expect(EntryDisclosure.durationText(3660) == "1 h 1 min")
        #expect(EntryDisclosure.durationText(3661) == "approximately 1 h 1 min")
        #expect(EntryDisclosure.durationText(17) == "less than a minute")
        #expect(EntryDisclosure.durationText(0) == "0 h 0 min")
        #expect(!EntryDisclosure.bound(instant, zone: zone).contains(String(instant)))
    }

    @Test func pendingOnlyReviewRequiresExplicitEndAndSkipUndo() throws {
        let p = Project(id: UUID(), name: "Project", hourlyRate: 0, currencyCode: "EUR")
        let owner = TaskRecord(id: UUID(), projectID: p.id, name: "Leaf")
        let pending = PendingSleepInterval(id: UUID(), taskID: owner.id, sleepAt: 100, wakeAt: nil)
        let s = LibrarySnapshot(schemaVersion: 2, revision: 0, projects: [p], tasks: [owner], entries: [], activeTimer: nil, pendingSleepIntervals: [pending])
        #expect(throws: (any Error).self) { try SleepPlanner.include(pending, endAt: nil, in: s) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let noEnd: LocalCorrectionTime? = nil
        #expect(throws: (any Error).self) {
            try SleepPlanner.include(pending, endAt: noEnd?.resolve(calendar: utc), in: s)
        }
        let seeded = CorrectionForm.fields(Date(timeIntervalSince1970: TimeInterval(pending.sleepAt)),
            calendar: utc, preservingPrecision: false)
        #expect(seeded.components.second == 0)
        #expect(throws: (any Error).self) {
            try SleepPlanner.include(pending, endAt: seeded.resolve(calendar: utc), in: s)
        }
        let explicit = CorrectionForm.applyingPickerDate(
            CorrectionForm.pickerDate(for: seeded).addingTimeInterval(180), to: seeded)
        let explicitInstant = try explicit.resolve(calendar: utc)
        #expect(explicitInstant == 240)
        #expect(try SleepPlanner.include(pending, endAt: explicitInstant, in: s).pending == pending)
        let known = PendingSleepInterval(id: UUID(), taskID: owner.id, sleepAt: 100, wakeAt: 217)
        let knownSnapshot = LibrarySnapshot(schemaVersion: 2, revision: 0, projects: [p], tasks: [owner],
            entries: [], activeTimer: nil, pendingSleepIntervals: [known])
        let knownPlan = try SleepPlanner.include(known, endAt: nil, in: knownSnapshot)
        switch knownPlan.correction.draft {
        case .add(_, _, let start, let stop), .edit(_, _, let start, let stop):
            #expect(start == 100)
            #expect(stop == 217)
        }
        let included = try SleepPlanner.include(pending, endAt: 200, in: s)
        #expect(included.pending == pending); #expect(included.path.text == "Project / Leaf")
        let skipped = try SleepPlanner.skip(pending, in: s); #expect(skipped.pending == pending)
        let entry = TimeEntry(id: UUID(), taskID: owner.id, startAt: 10, endAt: nil)
        let active = ActiveTimer(entryID: entry.id, checkpointAt: 90)
        let interrupted = LibrarySnapshot(schemaVersion: 2, revision: 0, projects: [p], tasks: [owner], entries: [entry], activeTimer: active, pendingSleepIntervals: [])
        #expect(try SleepPlanner.interruption(endAt: 90, in: interrupted).requestedEnd == 90)
        #expect(try SleepPlanner.interruption(endAt: nil, in: interrupted).correction == nil)
    }
    @Test func pinnedReviewLayoutPreservesEvidenceAndActionSemantics() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("UurtjeFactuurtje/TimeReviewView.swift"), encoding: .utf8)
        #expect(source.range(of: "var body: some View {\\s*VStack", options: .regularExpression) != nil)
        #expect(source.range(of: #"\}\s*\.frame\(maxWidth: \.infinity, maxHeight: \.infinity\)\s*HStack \{\s*Button\("Cancel""#, options: .regularExpression) != nil)
        #expect(source.range(of: #"Button\("Confirm reviewed action"\) \{ confirm\(\) \}\s*\.disabled\(stale"#, options: .regularExpression) != nil)
        #expect(source.contains("static func saveAndStop"))
        #expect(source.contains("static func interruptionSummary"))
    }
}
