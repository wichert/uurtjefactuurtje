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
    @Test func dstChoiceStableIDsPreviewBackAndStaleDisclosure() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), leaf = try await task(t, project: p)
            let s = try #require(t.workspace.snapshot)
            let f = try CorrectionForm(route: CorrectionRoute(id: UUID(), mode: .add(taskID: leaf)),
                snapshot: s, now: Date(timeIntervalSince1970: 1_800_000_000),
                timeZone: try #require(TimeZone(identifier: "Europe/Amsterdam")))
            f.start = LocalCorrectionTime(components: DateComponents(year: 2025, month: 10, day: 26, hour: 2, minute: 30, second: 0))
            guard case .ambiguous(let earlier, let later, _, _) = CorrectionClock.resolve(f.start.components, calendar: f.calendar) else { Issue.record("Expected overlap"); return }
            #expect(throws: (any Error).self) { try f.start.resolve(calendar: f.calendar) }
            f.start.select(earlier); f.end = CorrectionForm.fields(Date(timeIntervalSince1970: TimeInterval(later + 3600)), calendar: f.calendar, preservingPrecision: false)
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

    @Test func interruptionCheckpointSurvivesUntilBoundaryChangesAndZeroSaveCannotDiscard() async throws {
        try await withTrack { t, _ in
            let clock = NativeClock()
            clock.set(120)
            t.workspace.configureTimer(clock: { clock.read() })
            let p = try await project(t), leaf = try await task(t, project: p)
            _ = try await t.workspace.enqueueTimer(.start(taskID: leaf)).value
            clock.set(137)
            _ = try await t.workspace.enqueueTimer(.checkpoint).value
            await t.workspace.close()
            try await t.workspace.open() // Existing open entry now requires interruption review.
            let saved = try #require(t.workspace.snapshot)
            let active = try #require(saved.activeTimer)
            let entry = try #require(saved.entries.first(where: { $0.id == active.entryID }))
            #expect(entry.startAt == 120)
            #expect(active.checkpointAt == 137)
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
            let checkpoint = CorrectionForm.fields(Date(timeIntervalSince1970: TimeInterval(active.checkpointAt)),
                calendar: utc, preservingPrecision: true)
            let visible = CorrectionForm.pickerDate(for: checkpoint)
            let untouched = CorrectionForm.applyingPickerDate(visible, to: checkpoint)
            #expect(untouched == checkpoint)
            #expect(try untouched.resolve(calendar: utc) == 137)
            let review = try TimeReviewView.saveAndStop(end: untouched, calendar: utc, in: saved)
            #expect(review.requestedEnd == 137)
            #expect(EntryDisclosure.durationText(active.checkpointAt - entry.startAt) == "less than a minute")
            var moved = CorrectionForm.applyingPickerDate(visible.addingTimeInterval(60), to: checkpoint)
            #expect(moved.components.second == 0)
            #expect(moved.selectedInstant == nil)
            #expect(try moved.resolve(calendar: utc) == 180)
            moved = CorrectionForm.applyingPickerDate(visible, to: moved)
            #expect(try moved.resolve(calendar: utc) == entry.startAt)
            #expect(throws: (any Error).self) {
                try TimeReviewView.saveAndStop(end: moved, calendar: utc, in: saved)
            }
            // The UI cannot enqueue a zero-duration Save & Stop as a hidden discard.
            #expect(t.workspace.snapshot == saved)
            await t.workspace.close()
            try await t.workspace.open()
            let stillSaved = try #require(t.workspace.snapshot)
            #expect(stillSaved.entries == saved.entries)
            #expect(stillSaved.activeTimer == active)
            let fresh = try TimeReviewView.saveAndStop(end: untouched, calendar: utc, in: stillSaved)
            _ = try await t.workspace.enqueueTimeReview(.resolveInterruption(fresh)).value
            #expect(t.workspace.snapshot?.activeTimer == nil)
            await t.workspace.close()
            try await t.workspace.open()
            let persisted = try #require(t.workspace.snapshot?.entries.first(where: { $0.id == entry.id }))
            #expect(persisted.startAt == 120)
            #expect(persisted.endAt == 137)
            #expect(t.workspace.snapshot?.activeTimer == nil)
        }
    }

    @Test func explicitDiscardReviewDisclosesPreciseCheckpointAndAllRemovedTime() throws {
        let project = Project(id: UUID(), name: "Project", hourlyRate: 0, currencyCode: "EUR")
        let task = TaskRecord(id: UUID(), projectID: project.id, name: "Leaf")
        let entry = TimeEntry(id: UUID(), taskID: task.id, startAt: 120, endAt: nil)
        let active = ActiveTimer(entryID: entry.id, checkpointAt: 137)
        let snapshot = LibrarySnapshot(schemaVersion: 2, revision: 0, projects: [project], tasks: [task],
            entries: [entry], activeTimer: active, pendingSleepIntervals: [])
        let review = try SleepPlanner.interruption(endAt: nil, in: snapshot)
        let zone = try #require(TimeZone(secondsFromGMT: 0))
        let summary = TimeReviewView.interruptionSummary(review, zone: zone)
        #expect(review.active.checkpointAt == 137)
        #expect(review.active.checkpointAt - review.entry.startAt == 17)
        #expect(summary.contains("Discard interrupted entry on Project / Leaf."))
        #expect(summary.contains("Saved durable checkpoint: \(EntryDisclosure.bound(137, zone: zone))."))
        #expect(summary.contains("Checkpointed duration: less than a minute."))
        #expect(summary.contains("Explicit discard removes the interrupted entry, including all its checkpointed time."))
        #expect(summary.contains("No time is saved; no end is inferred."))
        #expect(review.requestedEnd == nil && review.correction == nil)
    }

    @Test func newBoundariesUseWholeMinutesAndZoneIsCapturedByValue() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), leaf = try await task(t, project: p)
            let s = try #require(t.workspace.snapshot)
            var sampledCurrentZone = try #require(TimeZone(identifier: "Europe/Amsterdam"))
            let captured = sampledCurrentZone
            let f = try CorrectionForm(route: CorrectionRoute(id: UUID(), mode: .add(taskID: leaf)),
                snapshot: s, now: Date(timeIntervalSince1970: 1_700_003_653), timeZone: sampledCurrentZone)
            let firstStart = try f.start.resolve(calendar: f.calendar)
            let firstEnd = try f.end.resolve(calendar: f.calendar)
            sampledCurrentZone = try #require(TimeZone(identifier: "Australia/Lord_Howe"))
            #expect(f.timeZone == captured)
            #expect(f.calendar.timeZone == captured)
            #expect(try f.start.resolve(calendar: f.calendar) == firstStart)
            #expect(try f.end.resolve(calendar: f.calendar) == firstEnd)
            let next = try CorrectionForm(route: CorrectionRoute(id: UUID(), mode: .add(taskID: leaf)),
                snapshot: s, now: Date(timeIntervalSince1970: 1_700_003_653), timeZone: sampledCurrentZone)
            #expect(next.timeZone == sampledCurrentZone)
            #expect(next.timeZone != f.timeZone)
            #expect(f.start.components.second == 0)
            #expect(f.end.components.second == 0)
            #expect(f.start.selectedInstant == nil)
            #expect(f.end.selectedInstant == nil)
            try f.review(in: s)
            _ = try await t.workspace.enqueueCorrection(.apply(try #require(f.preview))).value
            let row = try #require(t.workspace.snapshot?.entries.first(where: { $0.id == f.entryID }))
            #expect(row.startAt == firstStart)
            #expect(row.endAt == firstEnd)
            #expect(row.startAt % 60 == 0)
            #expect(row.endAt.map { $0 % 60 == 0 } == true)
        }
    }

    @Test func nativeCarrierKeepsGapsAndFoldsForStrictActualZoneResolution() throws {
        for (identifier, components) in [
            ("Europe/Amsterdam", DateComponents(year: 2026, month: 3, day: 29, hour: 2, minute: 30, second: 0)),
            ("Australia/Lord_Howe", DateComponents(year: 2026, month: 10, day: 4, hour: 2, minute: 15, second: 0)),
            ("Pacific/Apia", DateComponents(year: 2011, month: 12, day: 30, hour: 12, minute: 0, second: 0))
        ] {
            var actual = Calendar(identifier: .gregorian)
            actual.timeZone = try #require(TimeZone(identifier: identifier))
            let old = LocalCorrectionTime(components: DateComponents(year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 17))
            let carrier = try #require(CorrectionForm.pickerCalendar.date(from: components))
            let changed = CorrectionForm.applyingPickerDate(carrier, to: old)
            #expect(changed.components == components)
            #expect(CorrectionClock.resolve(changed.components, calendar: actual) == .nonexistent)
            #expect(throws: (any Error).self) { try changed.resolve(calendar: actual) }
        }
        for (identifier, components, separation) in [
            ("Europe/Amsterdam", DateComponents(year: 2026, month: 10, day: 25, hour: 2, minute: 30, second: 0), Int64(3600)),
            ("Australia/Lord_Howe", DateComponents(year: 2026, month: 4, day: 5, hour: 1, minute: 45, second: 0), Int64(1800))
        ] {
            var actual = Calendar(identifier: .gregorian)
            actual.timeZone = try #require(TimeZone(identifier: identifier))
            let carrier = try #require(CorrectionForm.pickerCalendar.date(from: components))
            let old = LocalCorrectionTime(components: DateComponents(year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 0))
            var changed = CorrectionForm.applyingPickerDate(carrier, to: old)
            guard case .ambiguous(let earlier, let later, _, _) = CorrectionClock.resolve(changed.components, calendar: actual) else {
                Issue.record("Expected repeated time in \(identifier)"); continue
            }
            #expect(later - earlier == separation)
            #expect(throws: (any Error).self) { try changed.resolve(calendar: actual) }
            changed.select(earlier)
            #expect(try changed.resolve(calendar: actual) == earlier)
            changed.select(later)
            #expect(try changed.resolve(calendar: actual) == later)
            let exact = CorrectionForm.fields(Date(timeIntervalSince1970: TimeInterval(later + 17)),
                calendar: actual, preservingPrecision: true)
            #expect(try exact.resolve(calendar: actual) == later + 17)
            let redundant = CorrectionForm.applyingPickerDate(CorrectionForm.pickerDate(for: exact), to: exact)
            #expect(redundant == exact)
            #expect(try redundant.resolve(calendar: actual) == later + 17)
            #expect(CorrectionForm.choosingOccurrence(later + 17, for: exact, calendar: actual) == exact)
            let otherOccurrence = CorrectionForm.choosingOccurrence(earlier + 17, for: exact, calendar: actual)
            #expect(otherOccurrence.components.second == 0)
            #expect(try otherOccurrence.resolve(calendar: actual) == earlier)
            let moved = CorrectionForm.applyingPickerDate(carrier.addingTimeInterval(60), to: exact)
            #expect(moved.selectedInstant == nil)
            #expect(moved.components.second == 0)
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

@Suite @MainActor struct EditorBaselineTests {
    @Test func legacyDraftMemberwiseInitializersRemainCompatible() {
        let p = ProjectDraft(id: UUID(), isNew: true, observedRevision: 4,
            name: "Draft", rateText: "0", currencyCode: "EUR",
            confirmedPreviousCurrency: nil, archiveConfirmed: false)
        let t = TaskDraft(id: UUID(), isNew: true, observedRevision: 4,
            projectID: UUID(), parentID: nil, name: "Draft", migrationAccepted: false,
            budgetEnabled: false, budgetHours: "", originalBudgetMinutes: nil, originalBudgetText: "")
        #expect(p.reviewedSnapshot == nil)
        #expect(t.reviewedSnapshot == nil)
        #expect(p.observedRevision == 4 && t.observedRevision == 4)
    }

    @Test func everyDraftFactoryCapturesConfirmedSnapshot() async throws {
        try await withTrack { t, _ in
            let empty = try #require(t.workspace.snapshot)
            t.editProject()
            guard case .project(let first) = t.sheet else { Issue.record("Missing new project"); return }
            #expect(first.reviewedSnapshot == empty && first.observedRevision == empty.revision)
            t.cancelSheet()
            let p = try await project(t), root = try await task(t, project: p, name: "Root")
            let leaf = try await task(t, project: p, parent: root, name: "Leaf")
            let current = try #require(t.workspace.snapshot)
            t.editProject(p)
            guard case .project(let projectDraft) = t.sheet else { Issue.record("Missing project edit"); return }
            #expect(projectDraft.reviewedSnapshot == current && projectDraft.observedRevision == current.revision)
            t.cancelSheet()
            t.newTask(projectID: p, parentID: root)
            guard case .task(let newDraft) = t.sheet else { Issue.record("Missing new task"); return }
            #expect(newDraft.reviewedSnapshot == current && newDraft.observedRevision == current.revision)
            t.cancelSheet()
            t.editTask(leaf)
            guard case .task(let edited) = t.sheet else { Issue.record("Missing task edit"); return }
            #expect(edited.reviewedSnapshot == current && edited.observedRevision == current.revision)
            t.editConstrainingBudget(taskID: root)
            guard case .task(let ancestor) = t.sheet else { Issue.record("Missing ancestor edit"); return }
            #expect(ancestor.id == root && ancestor.reviewedSnapshot == current)
            #expect(ancestor.observedRevision == current.revision)
            #expect(t.suspendedTaskDraft?.reviewedSnapshot == current)
        }
    }

    @Test func checkpointDoesNotRebaseOpenDraftsOrConsumeConsent() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), leaf = try await task(t, project: p)
            t.workspace.configureTimer(clock: { 100 })
            let running = try await t.workspace.enqueueTimer(.start(taskID: leaf)).value
            t.newTask(projectID: p, parentID: leaf)
            guard case .task(var draft) = t.sheet else { Issue.record("Missing task draft"); return }
            draft.name = "Unsent"
            draft.migrationAccepted = true
            t.updateTaskDraft(draft)
            t.workspace.configureTimer(clock: { 120 })
            let tick = try await t.workspace.enqueueTimer(.checkpoint).value
            guard case .task(let retained) = t.sheet else { Issue.record("Lost task draft"); return }
            #expect(retained.reviewedSnapshot == running)
            #expect(retained.observedRevision == running.revision)
            #expect(retained.migrationAccepted && retained.name == "Unsent")
            let taskBaseline = try #require(retained.reviewedSnapshot)
            #expect(taskBaseline.editorRelevantEquals(tick))
            t.cancelSheet()
            t.editProject(p)
            guard case .project(let projectDraft) = t.sheet else { Issue.record("Missing project draft"); return }
            t.workspace.configureTimer(clock: { 140 })
            let next = try await t.workspace.enqueueTimer(.checkpoint).value
            guard case .project(let retainedProject) = t.sheet else { Issue.record("Lost project draft"); return }
            #expect(retainedProject.reviewedSnapshot == projectDraft.reviewedSnapshot)
            let projectBaseline = try #require(retainedProject.reviewedSnapshot)
            #expect(projectBaseline.editorRelevantEquals(next))
            #expect(retainedProject.observedRevision == tick.revision)
        }
    }

    @Test func suspendedDraftPreservesBaselineOnCancelAndRealAncestorSave() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), root = try await task(t, project: p, name: "Root")
            let leaf = try await task(t, project: p, parent: root, name: "Leaf")
            t.editTask(leaf)
            guard case .task(var draft) = t.sheet else { Issue.record("Missing child"); return }
            let original = try #require(draft.reviewedSnapshot)
            draft.name = "Unsent name"
            draft.budgetEnabled = true
            draft.budgetHours = "17.5"
            draft.migrationAccepted = true
            t.updateTaskDraft(draft)
            let renamed = try await t.workspace.submit(.renameTask(id: root, name: "Changed root"),
                                                       expectedRevision: original.revision)
            t.editConstrainingBudget(taskID: root)
            guard case .task(let ancestor) = t.sheet else { Issue.record("Missing ancestor"); return }
            #expect(ancestor.reviewedSnapshot == renamed && ancestor.observedRevision == renamed.revision)
            #expect(t.suspendedTaskDraft?.reviewedSnapshot == original)
            t.cancelSheet()
            guard case .task(let canceled) = t.sheet else { Issue.record("Missing restored child"); return }
            #expect(canceled.reviewedSnapshot == original && canceled.observedRevision == original.revision)
            #expect(canceled.name == "Unsent name" && canceled.budgetHours == "17.5" && canceled.budgetEnabled)
            #expect(canceled.migrationAccepted)
            t.editConstrainingBudget(taskID: root)
            let token = t.routeToken
            guard case .task(let savingAncestor) = t.sheet else { Issue.record("Missing second ancestor"); return }
            #expect(t.begin(token))
            let saved = try await t.workspace.enqueueSubmit(
                .editTask(id: root, name: savingAncestor.name, budgetMinutes: 100_000),
                expectedRevision: savingAncestor.observedRevision, reviewedSnapshot: savingAncestor.reviewedSnapshot).value
            t.complete(token)
            guard case .task(let restored) = t.sheet else { Issue.record("Missing child after save"); return }
            #expect(t.suspendedTaskDraft == nil)
            #expect(restored.reviewedSnapshot == original && restored.observedRevision == original.revision)
            #expect(restored.name == "Unsent name" && restored.budgetHours == "17.5" && restored.budgetEnabled)
            #expect(restored.migrationAccepted)
            #expect(!original.editorRelevantEquals(saved))
            #expect(!t.acceptedWork)
        }
    }
}

@Suite @MainActor struct FormInputTests {
    @Test func projectChecksAreBoundedAndAllowDomainDuplicateNames() async throws {
        try await withTrack { t, _ in
            let p = try await project(t)
            t.editProject(p)
            guard case .project(var d) = t.sheet else { Issue.record("Missing project"); return }
            let s = try #require(t.workspace.snapshot)
            #expect(d.inputError(in: s) == nil)
            d.reviewedSnapshot = nil
            #expect(d.inputError(in: s) == nil)
            d.name = " \n\t"; #expect(d.inputError(in: s) == "Enter a project name.")
            d.name = "A\0B"; #expect(d.inputError(in: s) == "Remove the null character from the project name.")
            d.name = "  Project  "
            d.rateText = "-1"; #expect(d.inputError(in: s) == "Enter a nonnegative decimal rate without grouping separators.")
            d.rateText = "0"
            for bad in ["", "eur", "ZZZ", " EUR "] {
                d.currencyCode = bad
                #expect(d.inputError(in: s) == "Enter an uppercase ISO currency code, for example EUR or USD.")
            }
            d.currencyCode = "USD"; #expect(d.inputError(in: s) == nil)
            t.cancelSheet(); t.editProject()
            guard case .project(var new) = t.sheet else { Issue.record("Missing new project"); return }
            new.name = "Project"
            #expect(new.inputError(in: s) == nil)
            let saved = try await t.workspace.enqueueSubmit(.createProject(id: new.id, name: new.name, rate: 0, currency: "EUR"),
                expectedRevision: s.revision, reviewedSnapshot: new.reviewedSnapshot).value
            #expect(saved.projects.filter { $0.name == "Project" }.count == 2)
        }
    }

    @Test func siblingKeysExcludeSelfAndUseLatestRecordLocation() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), q = try await project(t, name: "Other")
            let root = try await task(t, project: p, name: "Root")
            let own = try await task(t, project: p, parent: root, name: "CAFÉ")
            _ = try await task(t, project: p, parent: root, name: "Sibling")
            _ = try await task(t, project: q, name: "Elsewhere")
            t.editTask(own)
            guard case .task(var d) = t.sheet else { Issue.record("Missing task"); return }
            let before = try #require(t.workspace.snapshot)
            d.name = " cafe\u{301} "
            #expect(d.inputError(in: before) == nil)
            d.reviewedSnapshot = nil
            #expect(d.inputError(in: before) == nil)
            d.name = " sibling "; d.projectID = q; d.parentID = nil
            #expect(d.inputError(in: before) == "A task with this name already exists under this parent. Choose a different name.")
            d.name = "Elsewhere"; #expect(d.inputError(in: before) == nil)
            d.name = " \n"; #expect(d.inputError(in: before) == "Enter a task name.")
            d.name = "A\0B"; #expect(d.inputError(in: before) == "Remove the null character from the task name.")
            t.cancelSheet(); t.newTask(projectID: p, parentID: root)
            guard case .task(var new) = t.sheet else { Issue.record("Missing creation draft"); return }
            new.name = "Cafe\u{301}"
            #expect(new.inputError(in: before) != nil)
            new.relocate(projectID: q, parentID: nil)
            #expect(new.inputError(in: before) == nil)
            new.relocate(projectID: p, parentID: root); new.name = "Fresh"
            #expect(new.inputError(in: before) == nil)
            _ = try await task(t, project: p, parent: root, name: "Fresh")
            let latest = try #require(t.workspace.snapshot)
            #expect(!before.editorRelevantEquals(latest))
            new.reviewedSnapshot = latest; new.observedRevision = latest.revision
            #expect(new.inputError(in: latest) == "A task with this name already exists under this parent. Choose a different name.")
            let result = t.workspace.enqueueTaskCreation(new.request(start: false), expectedRevision: latest.revision, reviewedSnapshot: latest)
            do { _ = try await result.value; Issue.record("Domain accepted duplicate sibling") }
            catch { #expect(error is LibraryError) }
            #expect(t.workspace.snapshot == latest)
        }
    }

    @Test func realAncestorSaveRestoresDraftWithoutNavigation() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), root = try await task(t, project: p, name: "Root")
            let leaf = try await task(t, project: p, parent: root, name: "Leaf")
            t.revealTask(leaf)
            let reveal = t.reveal?.id
            t.destination = .reports; t.search = "retained filter"
            t.editTask(leaf)
            guard case .task(var child) = t.sheet else { Issue.record("Missing child"); return }
            child.name = "Unsent"; child.budgetEnabled = true; child.budgetHours = "17.5"; child.migrationAccepted = true
            t.updateTaskDraft(child)
            t.editConstrainingBudget(taskID: root)
            guard case .task(let ancestor) = t.sheet else { Issue.record("Missing ancestor"); return }
            let token = t.routeToken
            #expect(t.begin(token))
            let saved = try await t.workspace.enqueueSubmit(.editTask(id: root, name: "Root edited", budgetMinutes: 100_000),
                expectedRevision: ancestor.observedRevision, reviewedSnapshot: ancestor.reviewedSnapshot).value
            t.complete(token)
            guard case .task(let restored) = t.sheet else { Issue.record("Child not restored"); return }
            #expect(t.suspendedTaskDraft == nil && !t.acceptedWork)
            #expect(restored.id == child.id && restored.name == child.name)
            #expect(restored.budgetEnabled == child.budgetEnabled && restored.budgetHours == child.budgetHours)
            #expect(restored.originalBudgetMinutes == child.originalBudgetMinutes && restored.originalBudgetText == child.originalBudgetText)
            #expect(restored.migrationAccepted == child.migrationAccepted)
            #expect(restored.reviewedSnapshot == child.reviewedSnapshot && restored.observedRevision == child.observedRevision)
            #expect(t.selectedProjectID == p && t.selectedTaskID == leaf)
            #expect(t.destination == .reports && t.search == "retained filter" && t.reveal?.id == reveal)
            let baseline = try #require(restored.reviewedSnapshot)
            #expect(!baseline.editorRelevantEquals(saved))
        }
    }
}

@Suite @MainActor struct ContextualTaskBudgetTests {
    private func draft(minutes: Int64?, locale: Locale, isNew: Bool = false) -> TaskDraft {
        let text = minutes.map { BudgetInput.text($0, locale: locale) } ?? ""
        return TaskDraft(id: UUID(), isNew: isNew, observedRevision: 0,
            projectID: UUID(), parentID: nil, name: "Draft", migrationAccepted: false,
            budgetEnabled: minutes != nil, budgetHours: text,
            originalBudgetMinutes: minutes, originalBudgetText: text)
    }

    @Test func roundedGeneratedStepsStayExactAcrossLocalesAndManualChanges() {
        for locale in [Locale(identifier: "en_US"), Locale(identifier: "nl_NL")] {
            var d = draft(minutes: 1, locale: locale)
            #expect(BudgetInput.parseHours(d.budgetHours, locale: locale) == nil)
            #expect(d.budgetValue(locale: locale) == 1)
            #expect(d.budgetAfterStep(by: -30, locale: locale) == nil)
            let original = d.budgetHours
            d.stepBudget(by: -30, locale: locale)
            #expect(d.budgetHours == original)
            d.stepBudget(by: 30, locale: locale)
            #expect(d.budgetHours == BudgetInput.text(31, locale: locale))
            #expect(d.generatedBudgetMinutes == 31)
            #expect(BudgetInput.parseHours(d.budgetHours, locale: locale) == nil)
            #expect(d.budgetValue(locale: locale) == 31)
            d.stepBudget(by: 30, locale: locale)
            #expect(d.budgetValue(locale: locale) == 61)
            d.stepBudget(by: -30, locale: locale)
            d.stepBudget(by: -30, locale: locale)
            #expect(d.budgetValue(locale: locale) == 1)
            d.budgetHours = "not hours"
            #expect(d.budgetValue(locale: locale) == nil)
            #expect(d.budgetAfterStep(by: 30, locale: locale) == nil)
            d.stepBudget(by: 30, locale: locale)
            #expect(d.budgetHours == "not hours")
            d.budgetHours = "1\(locale.decimalSeparator!)5"
            #expect(d.budgetValue(locale: locale) == 90)
            d.stepBudget(by: 30, locale: locale)
            #expect(d.budgetValue(locale: locale) == 120)
            d.budgetEnabled = false
            #expect(d.budgetValue(locale: locale) == nil)
            #expect(d.budgetAfterStep(by: 30, locale: locale) == nil)
            d.budgetEnabled = true
            #expect(d.budgetValue(locale: locale) == 120)
        }
    }

    @Test func emptyInvalidPositiveAndOverflowBoundaries() {
        let locale = Locale(identifier: "en_US_POSIX")
        var empty = draft(minutes: nil, locale: locale, isNew: true)
        empty.budgetEnabled = true
        #expect(empty.budgetValue(locale: locale) == nil)
        #expect(empty.budgetAfterStep(by: -30, locale: locale) == nil)
        empty.budgetHours = " \n "
        empty.stepBudget(by: 30, locale: locale)
        #expect(empty.budgetValue(locale: locale) == 30)
        #expect(empty.budgetAfterStep(by: -30, locale: locale) == nil)
        empty.stepBudget(by: -30, locale: locale)
        #expect(empty.budgetValue(locale: locale) == 30)
        for text in ["0", "-1", "0.001", "1e3", "1,000", "2x", "1537228672809129310"] {
            empty.budgetHours = text
            #expect(empty.budgetValue(locale: locale) == nil)
            #expect(empty.budgetAfterStep(by: 30, locale: locale) == nil)
            empty.stepBudget(by: 30, locale: locale)
            #expect(empty.budgetHours == text)
        }
        var edge = draft(minutes: Int64.max - 30, locale: locale)
        edge.stepBudget(by: 30, locale: locale)
        #expect(edge.budgetValue(locale: locale) == Int64.max)
        let maxText = edge.budgetHours
        #expect(edge.budgetAfterStep(by: 30, locale: locale) == nil)
        edge.stepBudget(by: 30, locale: locale)
        #expect(edge.budgetHours == maxText)
        #expect(edge.budgetValue(locale: locale) == Int64.max)
        edge.stepBudget(by: -30, locale: locale)
        #expect(edge.budgetValue(locale: locale) == Int64.max - 30)
        var oneAbove = draft(minutes: Int64.max - 29, locale: locale)
        #expect(oneAbove.budgetAfterStep(by: 30, locale: locale) == nil)
        oneAbove.stepBudget(by: 30, locale: locale)
        #expect(oneAbove.budgetValue(locale: locale) == Int64.max - 29)
        var invalidOriginal = draft(minutes: 0, locale: locale)
        #expect(invalidOriginal.budgetValue(locale: locale) == nil)
        invalidOriginal = draft(minutes: -1, locale: locale)
        #expect(invalidOriginal.budgetValue(locale: locale) == nil)
    }

    @Test func creationAndEditingRejectInvalidEnabledBudgetBeforeRequest() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), leaf = try await task(t, project: p)
            for isNew in [true, false] {
                if isNew { t.newTask(projectID: p) } else { t.editTask(leaf) }
                guard case .task(var d) = t.sheet else { Issue.record("Missing draft"); return }
                d.name = "Valid name"
                let s = try #require(t.workspace.snapshot)
                d.budgetEnabled = true
                for invalid in ["", "0", "-1", "garbage", "0\(Locale.current.decimalSeparator ?? ".")001"] {
                    d.budgetHours = invalid
                    #expect(d.inputError(in: s) == "Enter positive budget hours that represent a whole number of minutes.")
                }
                d.budgetEnabled = false
                #expect(d.inputError(in: s) == nil)
                #expect(d.request(start: false).budgetMinutes == nil)
                d.budgetEnabled = true
                d.budgetHours = "2"
                #expect(d.inputError(in: s) == nil)
                #expect(d.parsedBudget == 120)
                #expect(t.workspace.snapshot == s)
                t.cancelSheet()
            }
        }
    }

    @Test func contextualCreationCarriesBudgetForBothCommandsAndBudgetCanBeCleared() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), root = try await task(t, project: p, name: "Root")
            for start in [false, true] {
                t.newTask(projectID: p, parentID: root)
                guard case .task(var d) = t.sheet else { Issue.record("Missing new task"); return }
                #expect(!d.budgetEnabled && d.budgetHours.isEmpty && d.originalBudgetMinutes == nil)
                #expect(d.projectID == p && d.parentID == root)
                d.name = start ? "Running" : "Saved"
                d.budgetEnabled = true
                d.stepBudget(by: 30)
                let s = try #require(t.workspace.snapshot)
                #expect(d.inputError(in: s) == nil)
                let request = d.request(start: start)
                #expect(request.id == d.id && request.projectID == p && request.parentID == root)
                #expect(request.budgetMinutes == 30 && request.start == start)
                let created = try await t.workspace.enqueueTaskCreation(request, expectedRevision: d.observedRevision,
                    reviewedSnapshot: d.reviewedSnapshot).value
                #expect(created.snapshot.tasks.first(where: { $0.id == d.id })?.budgetMinutes == 30)
                if start {
                    let active = try #require(created.snapshot.activeTimer)
                    #expect(created.snapshot.entries.first(where: { $0.id == active.entryID })?.taskID == d.id)
                    _ = try await t.workspace.enqueueTimer(.stop(expectedEntryID: active.entryID)).value
                } else { #expect(created.snapshot.activeTimer == nil) }
                t.cancelSheet()
                t.editTask(d.id)
                guard case .task(var edit) = t.sheet else { Issue.record("Missing edit"); return }
                #expect(edit.originalBudgetMinutes == 30 && edit.parsedBudget == 30)
                edit.budgetEnabled = false
                let latest = try #require(t.workspace.snapshot)
                _ = try await t.workspace.enqueueSubmit(.editTask(id: edit.id, name: edit.name, budgetMinutes: edit.parsedBudget),
                    expectedRevision: latest.revision, reviewedSnapshot: edit.reviewedSnapshot).value
                #expect(t.workspace.snapshot?.tasks.first(where: { $0.id == edit.id })?.budgetMinutes == nil)
                t.cancelSheet()
            }
        }
    }

    @Test func budgetedMigrationStillRequiresConsentAndKeepsGenericBudgetless() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), parent = try await task(t, project: p)
            let before = try #require(t.workspace.snapshot)
            let preview = try CorrectionPlanner.preview(.add(id: UUID(), taskID: parent, startAt: 100, endAt: 200), in: before)
            _ = try await t.workspace.enqueueCorrection(.apply(preview)).value
            t.newTask(projectID: p, parentID: parent)
            guard case .task(var d) = t.sheet else { Issue.record("Missing draft"); return }
            d.name = "Budgeted child"; d.budgetEnabled = true; d.budgetHours = "2"
            let s = try #require(t.workspace.snapshot)
            do {
                _ = try await t.workspace.enqueueTaskCreation(d.request(start: false), expectedRevision: d.observedRevision,
                    reviewedSnapshot: d.reviewedSnapshot).value
                Issue.record("Unconfirmed budgeted migration succeeded")
            } catch { #expect(t.workspace.snapshot == s) }
            d.migrationAccepted = true
            let result = try await t.workspace.enqueueTaskCreation(d.request(start: false), expectedRevision: d.observedRevision,
                reviewedSnapshot: d.reviewedSnapshot).value
            let generic = try #require(result.genericID)
            #expect(result.movedEntryCount == 1)
            #expect(result.snapshot.tasks.first(where: { $0.id == d.id })?.budgetMinutes == 120)
            #expect(result.snapshot.tasks.first(where: { $0.id == generic })?.budgetMinutes == nil)
            #expect(result.snapshot.entries.first?.taskID == generic)
        }
    }

    @Test func allowanceIsMinuteExactAndOverBudgetCreationDoesNotCommit() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), root = try await task(t, project: p, name: "Root")
            let sibling = try await task(t, project: p, parent: root, name: "Sibling")
            var s = try #require(t.workspace.snapshot)
            _ = try await t.workspace.enqueueSubmit(.editTask(id: root, name: "Root", budgetMinutes: 120), expectedRevision: s.revision).value
            s = try #require(t.workspace.snapshot)
            _ = try await t.workspace.enqueueSubmit(.editTask(id: sibling, name: "Sibling", budgetMinutes: 90), expectedRevision: s.revision).value
            t.newTask(projectID: p, parentID: root)
            guard case .task(var d) = t.sheet else { Issue.record("Missing draft"); return }
            d.name = "Too much"; d.budgetEnabled = true; d.budgetHours = "1"
            s = try #require(t.workspace.snapshot)
            let allowance = try BudgetRules.allowance(in: s, projectID: p, parentTaskID: root, editingTaskID: nil)
            #expect(allowance.minimumMinutes == 0 && allowance.maximumMinutes == 30)
            #expect(allowance.limitingAncestorID == root)
            do {
                _ = try await t.workspace.enqueueTaskCreation(d.request(start: false), expectedRevision: d.observedRevision,
                    reviewedSnapshot: d.reviewedSnapshot).value
                Issue.record("Over-budget creation succeeded")
            } catch {
                guard case CommandError.budgetAllocation(let id, let returned) = error else { throw error }
                #expect(id == d.id && returned == allowance)
                #expect(t.workspace.snapshot == s)
            }
        }
    }

    @Test func generatedCacheAndConsentSurviveAncestorCancelAndSaveWithoutRebasing() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), root = try await task(t, project: p, name: "Root")
            t.newTask(projectID: p, parentID: root)
            guard case .task(var d) = t.sheet else { Issue.record("Missing child"); return }
            d.name = "Unsent child"; d.budgetEnabled = true
            // Exactly three minutes in either supported decimal locale.
            d.budgetHours = "0\(Locale.current.decimalSeparator ?? ".")05"
            d.stepBudget(by: 30)
            #expect(d.parsedBudget == 33)
            d.migrationAccepted = true
            t.updateTaskDraft(d)
            let original = try #require(d.reviewedSnapshot)
            for save in [false, true] {
                t.editConstrainingBudget(taskID: root)
                #expect(t.suspendedTaskDraft?.generatedBudgetMinutes == 33)
                guard case .task(let ancestor) = t.sheet else { Issue.record("Missing ancestor"); return }
                if save {
                    let token = t.routeToken
                    #expect(t.begin(token))
                    _ = try await t.workspace.enqueueSubmit(.editTask(id: root, name: ancestor.name, budgetMinutes: 120),
                        expectedRevision: ancestor.observedRevision, reviewedSnapshot: ancestor.reviewedSnapshot).value
                    t.complete(token)
                } else { t.cancelSheet() }
                guard case .task(let restored) = t.sheet else { Issue.record("Lost child"); return }
                #expect(restored.id == d.id && restored.projectID == p && restored.parentID == root)
                #expect(restored.name == d.name && restored.migrationAccepted)
                #expect(restored.budgetHours == d.budgetHours && restored.parsedBudget == 33)
                #expect(restored.generatedBudgetMinutes == d.generatedBudgetMinutes)
                #expect(restored.generatedBudgetText == d.generatedBudgetText)
                #expect(restored.reviewedSnapshot == original && restored.observedRevision == d.observedRevision)
            }
            let latest = try #require(t.workspace.snapshot)
            #expect(!original.editorRelevantEquals(latest))
            do {
                _ = try await t.workspace.enqueueTaskCreation(d.request(start: false), expectedRevision: d.observedRevision,
                    reviewedSnapshot: d.reviewedSnapshot).value
                Issue.record("Stale budgeted draft accepted")
            } catch { #expect(t.workspace.snapshot == latest) }
            #expect(t.suspendedTaskDraft == nil && !t.acceptedWork)
        }
    }

    @Test func fixedCreationLocationRejectsUnavailableProjectAndForeignParent() async throws {
        try await withTrack { t, _ in
            let p = try await project(t), q = try await project(t, name: "Other")
            let foreign = try await task(t, project: q)
            t.newTask(projectID: p)
            guard case .task(var d) = t.sheet else { Issue.record("Missing draft"); return }
            d.name = "New"
            let s = try #require(t.workspace.snapshot)
            #expect(d.inputError(in: s) == nil)
            d.parentID = foreign
            #expect(d.inputError(in: s) == "This parent is unavailable. Cancel and select a task in this project.")
            d.parentID = UUID()
            #expect(d.inputError(in: s) != nil)
            d.parentID = nil; d.projectID = UUID()
            #expect(d.inputError(in: s) == "This project is unavailable for new tasks. Cancel and select an active project.")
            d.projectID = p
            let archived = try await t.workspace.enqueueSubmit(.setArchived(id: p, archived: true), expectedRevision: s.revision).value
            #expect(d.inputError(in: archived) == "This project is unavailable for new tasks. Cancel and select an active project.")
        }
    }
}
