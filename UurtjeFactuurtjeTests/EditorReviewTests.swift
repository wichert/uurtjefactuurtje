import Foundation
import Testing

@testable import LibraryStore
@testable import UurtjeFactuurtje

extension EditorFlowTests {
  @Test func explicitDiscardReviewDisclosesPreciseCheckpointAndAllRemovedTime() throws {
    let project = Project(id: UUID(), name: "Project", hourlyRate: 0, currencyCode: "EUR")
    let task = TaskRecord(id: UUID(), projectID: project.id, name: "Leaf")
    let entry = TimeEntry(id: UUID(), taskID: task.id, startAt: 120, endAt: nil)
    let active = ActiveTimer(entryID: entry.id, checkpointAt: 137)
    let snapshot = LibrarySnapshot(
      schemaVersion: 2, revision: 0, projects: [project], tasks: [task],
      entries: [entry], activeTimer: active, pendingSleepIntervals: [])
    let review = try SleepPlanner.interruption(endAt: nil, in: snapshot)
    let zone = try #require(TimeZone(secondsFromGMT: 0))
    let summary = TimeReviewView.interruptionSummary(review, zone: zone)
    #expect(review.active.checkpointAt == 137)
    #expect(review.active.checkpointAt - review.entry.startAt == 17)
    #expect(summary.contains("Discard interrupted entry on Project / Leaf."))
    #expect(
      summary.contains("Saved durable checkpoint: \(EntryDisclosure.bound(137, zone: zone))."))
    #expect(summary.contains("Checkpointed duration: less than a minute."))
    #expect(
      summary.contains(
        "Explicit discard removes the interrupted entry, including all its checkpointed time."))
    #expect(summary.contains("No time is saved; no end is inferred."))
    #expect(review.requestedEnd == nil && review.correction == nil)
  }

  @Test func newBoundariesUseWholeMinutesAndZoneIsCapturedByValue() async throws {
    try await withTrack { track, _ in
      let projectID = try await project(track)
      let leaf = try await task(track, project: projectID)
      let seconds = try #require(track.workspace.snapshot)
      var sampledCurrentZone = try #require(TimeZone(identifier: "Europe/Amsterdam"))
      let captured = sampledCurrentZone
      let frame = try CorrectionForm(
        route: CorrectionRoute(id: UUID(), mode: .add(taskID: leaf)),
        snapshot: seconds, now: Date(timeIntervalSince1970: 1_700_003_653),
        timeZone: sampledCurrentZone)
      let firstStart = try frame.start.resolve(calendar: frame.calendar)
      let firstEnd = try frame.end.resolve(calendar: frame.calendar)
      sampledCurrentZone = try #require(TimeZone(identifier: "Australia/Lord_Howe"))
      #expect(frame.timeZone == captured)
      #expect(frame.calendar.timeZone == captured)
      #expect(try frame.start.resolve(calendar: frame.calendar) == firstStart)
      #expect(try frame.end.resolve(calendar: frame.calendar) == firstEnd)
      let next = try CorrectionForm(
        route: CorrectionRoute(id: UUID(), mode: .add(taskID: leaf)),
        snapshot: seconds, now: Date(timeIntervalSince1970: 1_700_003_653),
        timeZone: sampledCurrentZone)
      #expect(next.timeZone == sampledCurrentZone)
      #expect(next.timeZone != frame.timeZone)
      #expect(frame.start.components.second == 0)
      #expect(frame.end.components.second == 0)
      #expect(frame.start.selectedInstant == nil)
      #expect(frame.end.selectedInstant == nil)
      try frame.review(in: seconds)
      _ = try await track.workspace.enqueueCorrection(.apply(try #require(frame.preview))).value
      let row = try #require(
        track.workspace.snapshot?.entries.first(where: { $0.id == frame.entryID }))
      #expect(row.startAt == firstStart)
      #expect(row.endAt == firstEnd)
      #expect(row.startAt % 60 == 0)
      #expect(row.endAt.map { $0 % 60 == 0 } == true)
    }
  }

  @Test func nativeCarrierKeepsGapsAndFoldsForStrictActualZoneResolution() throws {
    try verifyNonexistentCarrierTimes()
    for (identifier, components, separation) in [
      (
        "Europe/Amsterdam",
        DateComponents(year: 2026, month: 10, day: 25, hour: 2, minute: 30, second: 0), Int64(3600)
      ),
      (
        "Australia/Lord_Howe",
        DateComponents(year: 2026, month: 4, day: 5, hour: 1, minute: 45, second: 0), Int64(1800)
      )
    ] {
      var actual = Calendar(identifier: .gregorian)
      actual.timeZone = try #require(TimeZone(identifier: identifier))
      let carrier = try #require(CorrectionForm.pickerCalendar.date(from: components))
      let old = LocalCorrectionTime(
        components: DateComponents(year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 0))
      var changed = CorrectionForm.applyingPickerDate(carrier, to: old)
      guard
        case .ambiguous(let earlier, let later, _, _) = CorrectionClock.resolve(
          changed.components, calendar: actual)
      else {
        Issue.record("Expected repeated time in \(identifier)")
        continue
      }
      #expect(later - earlier == separation)
      #expect(throws: (any Error).self) { try changed.resolve(calendar: actual) }
      changed.select(earlier)
      #expect(try changed.resolve(calendar: actual) == earlier)
      changed.select(later)
      #expect(try changed.resolve(calendar: actual) == later)
      let exact = CorrectionForm.fields(
        Date(timeIntervalSince1970: TimeInterval(later + 17)),
        calendar: actual, preservingPrecision: true)
      #expect(try exact.resolve(calendar: actual) == later + 17)
      let redundant = CorrectionForm.applyingPickerDate(
        CorrectionForm.pickerDate(for: exact), to: exact)
      #expect(redundant == exact)
      #expect(try redundant.resolve(calendar: actual) == later + 17)
      #expect(CorrectionForm.choosingOccurrence(later + 17, for: exact, calendar: actual) == exact)
      let otherOccurrence = CorrectionForm.choosingOccurrence(
        earlier + 17, for: exact, calendar: actual)
      #expect(otherOccurrence.components.second == 0)
      #expect(try otherOccurrence.resolve(calendar: actual) == earlier)
      let moved = CorrectionForm.applyingPickerDate(carrier.addingTimeInterval(60), to: exact)
      #expect(moved.selectedInstant == nil)
      #expect(moved.components.second == 0)
    }
  }

  private func verifyNonexistentCarrierTimes() throws {
    for (identifier, components) in [
      (
        "Europe/Amsterdam",
        DateComponents(year: 2026, month: 3, day: 29, hour: 2, minute: 30, second: 0)
      ),
      (
        "Australia/Lord_Howe",
        DateComponents(year: 2026, month: 10, day: 4, hour: 2, minute: 15, second: 0)
      ),
      (
        "Pacific/Apia",
        DateComponents(year: 2011, month: 12, day: 30, hour: 12, minute: 0, second: 0)
      )
    ] {
      var actual = Calendar(identifier: .gregorian)
      actual.timeZone = try #require(TimeZone(identifier: identifier))
      let old = LocalCorrectionTime(
        components: DateComponents(year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 17))
      let carrier = try #require(CorrectionForm.pickerCalendar.date(from: components))
      let changed = CorrectionForm.applyingPickerDate(carrier, to: old)
      #expect(changed.components == components)
      #expect(CorrectionClock.resolve(changed.components, calendar: actual) == .nonexistent)
      #expect(throws: (any Error).self) { try changed.resolve(calendar: actual) }
    }
  }
}
