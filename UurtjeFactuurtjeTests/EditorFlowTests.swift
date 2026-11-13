import Foundation
import Testing

@testable import LibraryStore
@testable import UurtjeFactuurtje

@Suite @MainActor struct EditorFlowTests {
    @Test func exactLocalizedRatesRejectRoundingAndPartialConsumption() throws {
        let usLocale = Locale(identifier: "en_US")
        let dutchLocale = Locale(identifier: "nl_NL")
        for locale in [usLocale, dutchLocale] {
            let sep = locale.decimalSeparator!
            #expect(RateInput.parse(" 0 ", locale: locale) == 0)
            #expect(RateInput.parse("123\(sep)456789", locale: locale) == Decimal(string: "123.456789"))
            let boundary = "12345678901234567890123456789012345678"
            let exact = try #require(Decimal(string: boundary, locale: usLocale))
            #expect(RateInput.parse(boundary, locale: locale) == exact)
            #expect(RateInput.parse(boundary + "901", locale: locale) == nil)
            #expect(RateInput.parse(String(repeating: "9", count: 200), locale: locale) == nil)
            for bad in [
                "", "-1", "NaN", "1e3", "12junk", "12\(sep)", "\(sep)5", "1\(sep)2\(sep)3", "1 000", "1,000.00",
                "1.000,00"
            ] {
                #expect(RateInput.parse(bad, locale: locale) == nil)
            }
            #expect(BudgetInput.parseHours("1\(sep)5", locale: locale) == 90)
            #expect(BudgetInput.parseHours("1\(sep)5junk", locale: locale) == nil)
        }
    }
    @Test func unchangedBudgetAndLocationConsent() {
        var draft = TaskDraft(
            id: UUID(), isNew: false, observedRevision: 4, projectID: UUID(), parentID: nil,
            name: "Draft", migrationAccepted: true, budgetEnabled: true, budgetHours: "rounded display",
            originalBudgetMinutes: 1, originalBudgetText: "rounded display")
        #expect(draft.parsedBudget == 1)
        draft.budgetHours = "not hours"
        #expect(draft.parsedBudget == nil)
        draft.budgetEnabled = false
        #expect(draft.parsedBudget == nil)
        draft.relocate(projectID: draft.projectID, parentID: UUID())
        #expect(!draft.migrationAccepted)
        let request = draft.request(start: true)
        #expect(request.id == draft.id)
        #expect(request.start)
        #expect(!request.confirmMigration)
    }
    @Test func suspendedDraftRestoresOnSaveAndCancel() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let root = try await task(track, project: projectID, name: "Root")
            let leaf = try await task(track, project: projectID, parent: root, name: "Leaf")
            track.editTask(leaf)
            guard case .task(var draft) = track.sheet else {
                Issue.record("Missing task")
                return
            }
            draft.name = "Unsent name"
            draft.budgetHours = "17.5"
            track.updateTaskDraft(draft)
            let statement = try #require(track.workspace.snapshot)
            _ = try BudgetRules.allowance(in: statement, projectID: projectID, parentTaskID: root, editingTaskID: leaf)
            _ = try BudgetRules.allocations(in: statement)
            track.editConstrainingBudget(taskID: root)
            #expect(track.suspendedTaskDraft?.name == "Unsent name")
            track.editConstrainingBudget(taskID: leaf)
            #expect(track.suspendedTaskDraft?.id == leaf)
            track.cancelSheet()
            guard case .task(let restored) = track.sheet else {
                Issue.record("Not restored")
                return
            }
            #expect(restored.name == "Unsent name")
            #expect(restored.budgetHours == "17.5")
            track.editConstrainingBudget(taskID: root)
            let token = track.routeToken
            #expect(track.begin(token))
            track.complete(token)
            guard case .task(let saved) = track.sheet else {
                Issue.record("Not restored after save")
                return
            }
            #expect(saved.id == leaf)
            #expect(track.suspendedTaskDraft == nil)
        }
    }
    @Test func migrationRevisionConsentAndCommittedStart() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let parent = try await task(track, project: projectID)
            let before = try #require(track.workspace.snapshot)
            let preview = try CorrectionPlanner.preview(
                .add(id: UUID(), taskID: parent, startAt: 100, endAt: 200),
                in: before)
            _ = try await track.workspace.enqueueCorrection(.apply(preview)).value
            let statement = try #require(track.workspace.snapshot)
            let child = UUID()
            do {
                _ = try await track.workspace.enqueueTaskCreation(
                    TaskCreationRequest(
                        id: child, projectID: projectID, parentID: parent, name: "New", confirmMigration: false,
                        start: false), expectedRevision: statement.revision
                ).value
                Issue.record("Unconfirmed migration succeeded")
            } catch { #expect(track.workspace.snapshot == statement) }
            let result = try await track.workspace.enqueueTaskCreation(
                TaskCreationRequest(
                    id: child, projectID: projectID, parentID: parent, name: "New",
                    confirmMigration: true, start: false),
                expectedRevision: statement.revision
            ).value
            #expect(result.movedEntryCount == 1)
            #expect(result.genericID != nil)
            guard case .available(let receiptID) = track.workspace.migrationUndoAvailability else {
                Issue.record("Missing guarded receipt")
                return
            }
            _ = try await track.workspace.enqueueMigrationUndo(receiptID: receiptID).value
            #expect(track.workspace.snapshot?.tasks.contains(where: { $0.id == child }) == false)
            do {
                _ = try await track.workspace.enqueueTaskCreation(
                    TaskCreationRequest(
                        id: UUID(), projectID: projectID, parentID: nil, name: "Stale", confirmMigration: false,
                        start: true), expectedRevision: statement.revision
                ).value
                Issue.record("Stale request succeeded")
            } catch { #expect(track.workspace.snapshot?.activeTimer == nil) }
            let current = try #require(track.workspace.snapshot)
            let running = UUID()
            let accepted = track.workspace.enqueueTaskCreation(
                TaskCreationRequest(
                    id: running, projectID: projectID, parentID: nil, name: "Start",
                    confirmMigration: false, start: true),
                expectedRevision: current.revision)
            #expect(track.workspace.snapshot == current)
            let committed = try await accepted.value
            #expect(committed.snapshot.activeTimer != nil)
            #expect(committed.snapshot.tasks.first(where: { $0.id == running })?.budgetMinutes == nil)
            _ = try await track.workspace.enqueueTimer(.stop(expectedEntryID: committed.snapshot.activeTimer?.entryID))
                .value
        }
    }
    @Test func currencyConfirmationAndArchiveRetention() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let leaf = try await task(track, project: projectID)
            let statement = try #require(track.workspace.snapshot)
            let preview = try CorrectionPlanner.preview(
                .add(id: UUID(), taskID: leaf, startAt: 100, endAt: 200),
                in: statement)
            _ = try await track.workspace.enqueueCorrection(.apply(preview)).value
            let before = try #require(track.workspace.snapshot)
            do {
                _ = try await track.workspace.submit(
                    .updateProject(
                        id: projectID, name: "Project", rate: 1, currency: "USD", confirmedPreviousCurrency: nil),
                    expectedRevision: before.revision)
                Issue.record("Missing currency consent accepted")
            } catch { #expect(track.workspace.snapshot == before) }
            _ = try await track.workspace.submit(
                .updateProject(
                    id: projectID, name: "Project", rate: 1, currency: "USD", confirmedPreviousCurrency: "EUR"),
                expectedRevision: before.revision)
            track.editProject(projectID)
            guard case .project(let draft) = track.sheet else {
                Issue.record("Missing draft")
                return
            }
            #expect(!draft.archiveConfirmed)
            #expect(draft.confirmedPreviousCurrency == nil)
            track.cancelSheet()
            let current = try #require(track.workspace.snapshot)
            _ = try await track.workspace.submit(
                .setArchived(id: projectID, archived: true),
                expectedRevision: current.revision)
            #expect(track.workspace.snapshot?.entries == before.entries)
        }
    }
    @Test func nativeMinuteBindingPreservesOtherSavedBoundaryAndPersistsExactInstants() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let leaf = try await task(track, project: projectID)
            let utc = try #require(TimeZone(secondsFromGMT: 0))
            let id = UUID()
            let lowerBound: Int64 = 1_700_000_017
            let upperBound: Int64 = 1_700_003_653
            let before = try #require(track.workspace.snapshot)
            let seed = try CorrectionPlanner.preview(
                .add(
                    id: id, taskID: leaf, startAt: lowerBound,
                    endAt: upperBound), in: before)
            _ = try await track.workspace.enqueueCorrection(.apply(seed)).value
            let saved = try #require(track.workspace.snapshot)
            let fixture = try CorrectionForm(
                route: CorrectionRoute(id: UUID(), mode: .edit(entryID: id)),
                snapshot: saved, now: Date(), timeZone: utc)
            let startOnly = try CorrectionForm(
                route: CorrectionRoute(id: UUID(), mode: .edit(entryID: id)),
                snapshot: saved, now: Date(), timeZone: utc)
            startOnly.start = CorrectionForm.applyingPickerDate(
                CorrectionForm.pickerDate(for: startOnly.start).addingTimeInterval(60), to: startOnly.start)
            try startOnly.review(in: saved)
            switch try #require(startOnly.preview).draft {
            case .add(_, _, _, let stop), .edit(_, _, _, let stop): #expect(stop == upperBound)
            }
            #expect(try startOnly.end.resolve(calendar: startOnly.calendar) == upperBound)
            let originalStart = fixture.start
            let originalEnd = fixture.end
            let visibleStart = CorrectionForm.pickerDate(for: fixture.start)
            #expect(CorrectionForm.pickerCalendar.component(.second, from: visibleStart) == 0)
            #expect(fixture.start == originalStart)
            #expect(CorrectionForm.applyingPickerDate(visibleStart, to: fixture.start) == originalStart)
            #expect(
                CorrectionForm.applyingPickerDate(
                    CorrectionForm.pickerDate(for: fixture.end),
                    to: fixture.end) == originalEnd)
            try fixture.review(in: saved)
            #expect(try fixture.start.resolve(calendar: fixture.calendar) == lowerBound)
            #expect(try fixture.end.resolve(calendar: fixture.calendar) == upperBound)
            fixture.back()
            fixture.end = CorrectionForm.applyingPickerDate(
                CorrectionForm.pickerDate(for: fixture.end).addingTimeInterval(60), to: fixture.end)
            let changedEnd = try fixture.end.resolve(calendar: fixture.calendar)
            #expect(fixture.end.components.second == 0)
            #expect(fixture.end.selectedInstant == nil)
            #expect(changedEnd == upperBound - upperBound % 60 + 60)
            #expect(try fixture.start.resolve(calendar: fixture.calendar) == lowerBound)
            try fixture.review(in: saved)
            _ = try await track.workspace.enqueueCorrection(.apply(try #require(fixture.preview))).value
            let after = try #require(track.workspace.snapshot)
            let row = try #require(after.entries.first(where: { $0.id == id }))
            #expect(row.startAt == lowerBound)
            #expect(row.endAt == changedEnd)
            let secondForm = try CorrectionForm(
                route: CorrectionRoute(id: UUID(), mode: .edit(entryID: id)),
                snapshot: after, now: Date(), timeZone: utc)
            secondForm.start = CorrectionForm.applyingPickerDate(
                CorrectionForm.pickerDate(for: secondForm.start).addingTimeInterval(60), to: secondForm.start)
            secondForm.start = CorrectionForm.applyingPickerDate(visibleStart, to: secondForm.start)
            #expect(secondForm.start.components.second == 0)
            #expect(try secondForm.start.resolve(calendar: secondForm.calendar) == lowerBound - lowerBound % 60)
            #expect(try secondForm.end.resolve(calendar: secondForm.calendar) == changedEnd)
            try secondForm.review(in: after)
            _ = try await track.workspace.enqueueCorrection(.apply(try #require(secondForm.preview))).value
            let final = try #require(track.workspace.snapshot?.entries.first(where: { $0.id == id }))
            #expect(final.startAt == lowerBound - lowerBound % 60)
            #expect(final.endAt == changedEnd)
        }
    }

    @Test func correctionDisclosureHasMinuteValuesAndInformativeOffsetsOnly() throws {
        let zone = try #require(TimeZone(identifier: "Europe/Amsterdam"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026, month: 1, day: 2, hour: 3, minute: 4,
                    second: 57)))
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
        let project = Project(id: UUID(), name: "Project", hourlyRate: 0, currencyCode: "EUR")
        let owner = TaskRecord(id: UUID(), projectID: project.id, name: "Leaf")
        let pending = PendingSleepInterval(id: UUID(), taskID: owner.id, sleepAt: 100, wakeAt: nil)
        let statement = LibrarySnapshot(
            schemaVersion: 2, revision: 0, projects: [project], tasks: [owner],
            entries: [], activeTimer: nil, pendingSleepIntervals: [pending])
        #expect(throws: (any Error).self) { try SleepPlanner.include(pending, endAt: nil, in: statement) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let noEnd: LocalCorrectionTime? = nil
        #expect(throws: (any Error).self) {
            try SleepPlanner.include(pending, endAt: noEnd?.resolve(calendar: utc), in: statement)
        }
        let seeded = CorrectionForm.fields(
            Date(timeIntervalSince1970: TimeInterval(pending.sleepAt)),
            calendar: utc, preservingPrecision: false)
        #expect(seeded.components.second == 0)
        #expect(throws: (any Error).self) {
            try SleepPlanner.include(pending, endAt: seeded.resolve(calendar: utc), in: statement)
        }
        let explicit = CorrectionForm.applyingPickerDate(
            CorrectionForm.pickerDate(for: seeded).addingTimeInterval(180), to: seeded)
        let explicitInstant = try explicit.resolve(calendar: utc)
        #expect(explicitInstant == 240)
        #expect(try SleepPlanner.include(pending, endAt: explicitInstant, in: statement).pending == pending)
        let known = PendingSleepInterval(id: UUID(), taskID: owner.id, sleepAt: 100, wakeAt: 217)
        let knownSnapshot = LibrarySnapshot(
            schemaVersion: 2, revision: 0, projects: [project], tasks: [owner],
            entries: [], activeTimer: nil, pendingSleepIntervals: [known])
        let knownPlan = try SleepPlanner.include(known, endAt: nil, in: knownSnapshot)
        switch knownPlan.correction.draft {
        case .add(_, _, let start, let stop), .edit(_, _, let start, let stop):
            #expect(start == 100)
            #expect(stop == 217)
        }
        let included = try SleepPlanner.include(pending, endAt: 200, in: statement)
        #expect(included.pending == pending)
        #expect(included.path.text == "Project / Leaf")
        let skipped = try SleepPlanner.skip(pending, in: statement)
        #expect(skipped.pending == pending)
        let entry = TimeEntry(id: UUID(), taskID: owner.id, startAt: 10, endAt: nil)
        let active = ActiveTimer(entryID: entry.id, checkpointAt: 90)
        let interrupted = LibrarySnapshot(
            schemaVersion: 2, revision: 0, projects: [project], tasks: [owner],
            entries: [entry], activeTimer: active, pendingSleepIntervals: [])
        #expect(try SleepPlanner.interruption(endAt: 90, in: interrupted).requestedEnd == 90)
        #expect(try SleepPlanner.interruption(endAt: nil, in: interrupted).correction == nil)
    }
    @Test func pinnedReviewLayoutPreservesEvidenceAndActionSemantics() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("UurtjeFactuurtje/TimeReviewView.swift"), encoding: .utf8)
        #expect(source.range(of: "var body: some View {\\s*VStack", options: .regularExpression) != nil)
        #expect(
            source.range(
                of: #"\}\s*\.frame\(maxWidth: \.infinity, maxHeight: \.infinity\)"# +
                    #"\s*HStack \{\s*Button\("Cancel""#,
                options: .regularExpression) != nil)
        #expect(
            source.range(
                of: #"Button\("Confirm reviewed action"\) \{ confirm\(\) \}\s*\.disabled\(stale"#,
                options: .regularExpression) != nil)
        #expect(source.contains("static func saveAndStop"))
        #expect(source.contains("static func interruptionSummary"))
    }
}
