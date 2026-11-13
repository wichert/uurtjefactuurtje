import Foundation
import Testing

@testable import LibraryStore
@testable import UurtjeFactuurtje

extension EditorFlowTests {
    private struct MinuteBounds {
        let id: UUID
        let low: Int64
        let high: Int64
    }

    private struct CheckpointContext {
        let visible: Date
        let checkpoint: LocalCorrectionTime
        let untouched: LocalCorrectionTime
        let utc: Calendar
    }

    @Test func dstChoiceStableIDsPreviewBackAndStaleDisclosure() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let leaf = try await task(track, project: projectID)
            let seconds = try #require(track.workspace.snapshot)
            let frame = try CorrectionForm(
                route: CorrectionRoute(id: UUID(), mode: .add(taskID: leaf)),
                snapshot: seconds, now: Date(timeIntervalSince1970: 1_800_000_000),
                timeZone: try #require(TimeZone(identifier: "Europe/Amsterdam")))
            frame.start = LocalCorrectionTime(
                components: DateComponents(year: 2025, month: 10, day: 26, hour: 2, minute: 30, second: 0))
            guard
                case .ambiguous(let earlier, let later, _, _) = CorrectionClock.resolve(
                    frame.start.components, calendar: frame.calendar)
            else {
                Issue.record("Expected overlap")
                return
            }
            #expect(throws: (any Error).self) { try frame.start.resolve(calendar: frame.calendar) }
            frame.start.select(earlier)
            frame.end = CorrectionForm.fields(
                Date(timeIntervalSince1970: TimeInterval(later + 3600)), calendar: frame.calendar,
                preservingPrecision: false)
            // The chosen end is unambiguous; the repeated start requires the explicit choice above.
            try frame.review(in: seconds)
            let id = frame.entryID
            let preview = try #require(frame.preview)
            #expect(preview.targetPath.text == "Project / Task")
            frame.invalidateConfirmation()
            #expect(frame.confirmationIsStale)
            #expect(frame.preview == preview)
            frame.back()
            #expect(frame.preview == nil)
            #expect(frame.entryID == id)
            try frame.review(in: seconds)
            _ = try await track.workspace.enqueueCorrection(.apply(try #require(frame.preview))).value
            #expect(track.workspace.canUndoCorrection)
            _ = try await track.workspace.enqueueCorrection(.undo).value
            #expect(!track.workspace.canUndoCorrection)
            #expect(!track.workspace.canUndoTimeReview)
        }
    }
    @Test func nativeMinuteBindingPersistsExactInstants() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let leaf = try await task(track, project: projectID)
            let utc = try #require(TimeZone(secondsFromGMT: 0))
            let id = UUID()
            let low: Int64 = 1_700_000_017
            let high: Int64 = 1_700_003_653
            let before = try #require(track.workspace.snapshot)
            let seed = try CorrectionPlanner.preview(
                .add(id: id, taskID: leaf, startAt: low, endAt: high), in: before)
            _ = try await track.workspace.enqueueCorrection(.apply(seed)).value
            let saved = try #require(track.workspace.snapshot)
            let frame = try CorrectionForm(
                route: CorrectionRoute(id: UUID(), mode: .edit(entryID: id)),
                snapshot: saved, now: Date(), timeZone: utc)
            let startOnly = try CorrectionForm(
                route: CorrectionRoute(id: UUID(), mode: .edit(entryID: id)),
                snapshot: saved, now: Date(), timeZone: utc)
            startOnly.start = CorrectionForm.applyingPickerDate(
                CorrectionForm.pickerDate(for: startOnly.start).addingTimeInterval(60), to: startOnly.start)
            try startOnly.review(in: saved)
            switch try #require(startOnly.preview).draft {
            case .add(_, _, _, let stop), .edit(_, _, _, let stop): #expect(stop == high)
            }
            #expect(try startOnly.end.resolve(calendar: startOnly.calendar) == high)
            try await verifyMinuteBindingPersistence(
                frame: frame, saved: saved, bounds: MinuteBounds(id: id, low: low, high: high), utc: utc,
                track: track)
        }
    }

    @Test func interruptionCheckpointSurvivesUntilBoundaryChangesAndZeroSaveCannotDiscard()
        async throws {
        try await withTrack { track, _ in
            let clock = NativeClock()
            clock.set(120)
            track.workspace.configureTimer(clock: { clock.read() })
            let projectID = try await project(track)
            let leaf = try await task(track, project: projectID)
            _ = try await track.workspace.enqueueTimer(.start(taskID: leaf)).value
            clock.set(137)
            _ = try await track.workspace.enqueueTimer(.checkpoint).value
            await track.workspace.close()
            try await track.workspace.open()  // Existing open entry now requires interruption review.
            let saved = try #require(track.workspace.snapshot)
            let active = try #require(saved.activeTimer)
            let entry = try #require(saved.entries.first(where: { $0.id == active.entryID }))
            #expect(entry.startAt == 120)
            #expect(active.checkpointAt == 137)
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
            let checkpoint = CorrectionForm.fields(
                Date(timeIntervalSince1970: TimeInterval(active.checkpointAt)),
                calendar: utc, preservingPrecision: true)
            let visible = CorrectionForm.pickerDate(for: checkpoint)
            let untouched = CorrectionForm.applyingPickerDate(visible, to: checkpoint)
            #expect(untouched == checkpoint)
            #expect(try untouched.resolve(calendar: utc) == 137)
            let review = try TimeReviewView.saveAndStop(end: untouched, calendar: utc, in: saved)
            #expect(review.requestedEnd == 137)
            #expect(
                EntryDisclosure.durationText(active.checkpointAt - entry.startAt)
                    == "less than a minute")
            try await verifyCheckpointReopen(
                track: track, saved: saved, active: active, entry: entry,
                context: CheckpointContext(
                    visible: visible, checkpoint: checkpoint, untouched: untouched, utc: utc))
        }
    }

    private func verifyMinuteBindingPersistence(
        frame: CorrectionForm, saved: LibrarySnapshot,
        bounds: MinuteBounds, utc: TimeZone, track: TrackPresentation
    ) async throws {
        let id = bounds.id
        let low = bounds.low
        let high = bounds.high
        let originalStart = frame.start
        let originalEnd = frame.end
        let visibleStart = CorrectionForm.pickerDate(for: frame.start)
        #expect(CorrectionForm.pickerCalendar.component(.second, from: visibleStart) == 0)
        #expect(frame.start == originalStart)
        #expect(CorrectionForm.applyingPickerDate(visibleStart, to: frame.start) == originalStart)
        #expect(
            CorrectionForm.applyingPickerDate(CorrectionForm.pickerDate(for: frame.end), to: frame.end)
                == originalEnd)
        try frame.review(in: saved)
        #expect(try frame.start.resolve(calendar: frame.calendar) == low)
        #expect(try frame.end.resolve(calendar: frame.calendar) == high)
        frame.back()
        frame.end = CorrectionForm.applyingPickerDate(
            CorrectionForm.pickerDate(for: frame.end).addingTimeInterval(60), to: frame.end)
        let changedEnd = try frame.end.resolve(calendar: frame.calendar)
        #expect(frame.end.components.second == 0)
        #expect(frame.end.selectedInstant == nil)
        #expect(changedEnd == high - high % 60 + 60)
        #expect(try frame.start.resolve(calendar: frame.calendar) == low)
        try frame.review(in: saved)
        _ = try await track.workspace.enqueueCorrection(.apply(try #require(frame.preview))).value
        let after = try #require(track.workspace.snapshot)
        let row = try #require(after.entries.first(where: { $0.id == id }))
        #expect(row.startAt == low)
        #expect(row.endAt == changedEnd)
        let gate = try CorrectionForm(
            route: CorrectionRoute(id: UUID(), mode: .edit(entryID: id)),
            snapshot: after, now: Date(), timeZone: utc)
        gate.start = CorrectionForm.applyingPickerDate(
            CorrectionForm.pickerDate(for: gate.start).addingTimeInterval(60), to: gate.start)
        gate.start = CorrectionForm.applyingPickerDate(visibleStart, to: gate.start)
        #expect(gate.start.components.second == 0)
        #expect(try gate.start.resolve(calendar: gate.calendar) == low - low % 60)
        #expect(try gate.end.resolve(calendar: gate.calendar) == changedEnd)
        try gate.review(in: after)
        _ = try await track.workspace.enqueueCorrection(.apply(try #require(gate.preview))).value
        let final = try #require(track.workspace.snapshot?.entries.first(where: { $0.id == id }))
        #expect(final.startAt == low - low % 60)
        #expect(final.endAt == changedEnd)
    }

    private func verifyCheckpointReopen(
        track: TrackPresentation, saved: LibrarySnapshot, active: ActiveTimer, entry: TimeEntry,
        context: CheckpointContext
    ) async throws {
        let visible = context.visible
        let checkpoint = context.checkpoint
        let untouched = context.untouched
        let utc = context.utc
        var moved = CorrectionForm.applyingPickerDate(visible.addingTimeInterval(60), to: checkpoint)
        #expect(moved.components.second == 0)
        #expect(moved.selectedInstant == nil)
        #expect(try moved.resolve(calendar: utc) == 180)
        moved = CorrectionForm.applyingPickerDate(visible, to: moved)
        #expect(try moved.resolve(calendar: utc) == entry.startAt)
        #expect(throws: (any Error).self) {
            try TimeReviewView.saveAndStop(end: moved, calendar: utc, in: saved)
        }
        // The UI cannot enqueue first zero-duration Save & Stop as first hidden discard.
        #expect(track.workspace.snapshot == saved)
        await track.workspace.close()
        try await track.workspace.open()
        let stillSaved = try #require(track.workspace.snapshot)
        #expect(stillSaved.entries == saved.entries)
        #expect(stillSaved.activeTimer == active)
        let fresh = try TimeReviewView.saveAndStop(end: untouched, calendar: utc, in: stillSaved)
        _ = try await track.workspace.enqueueTimeReview(.resolveInterruption(fresh)).value
        #expect(track.workspace.snapshot?.activeTimer == nil)
        await track.workspace.close()
        try await track.workspace.open()
        let persisted = try #require(
            track.workspace.snapshot?.entries.first(where: { $0.id == entry.id }))
        #expect(persisted.startAt == 120)
        #expect(persisted.endAt == 137)
        #expect(track.workspace.snapshot?.activeTimer == nil)
    }

}
