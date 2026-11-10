import Foundation
import Testing
@testable import LibraryStore

@Test func recordValuesPreserveFieldsAndDefaults() async {
    let project = Project(id: UUID(), name: "Client", hourlyRate: Decimal(string: "123.456789")!, currencyCode: "EUR")
    let task = TaskRecord(id: UUID(), projectID: project.id, name: "Work")
    let entry = TimeEntry(id: UUID(), taskID: task.id, startAt: 10, endAt: nil)
    let active = ActiveTimer(entryID: entry.id, checkpointAt: 20)
    let pending = PendingSleepInterval(id: UUID(), taskID: task.id, sleepAt: 1, wakeAt: nil)
    let snapshot = LibrarySnapshot(schemaVersion: 2, revision: 4, projects: [project], tasks: [task],
                                   entries: [entry], activeTimer: active, pendingSleepIntervals: [pending])
    let copy = await Task.detached { snapshot }.value
    #expect(copy == snapshot)
    #expect(copy.projects[0].hourlyRate == Decimal(string: "123.456789")!)
    #expect(!project.isArchived)
    #expect(task.parentTaskID == nil && task.budgetMinutes == nil)
    #expect(task.lastWarnedThreshold == .none)
    #expect(WarningThreshold.allCases.map(\.rawValue) == [0, 80, 100])
    #expect(snapshot.entries[0].endAt == nil)
    #expect(snapshot.pendingSleepIntervals[0].wakeAt == nil)
}

@Test func nameKeysFoldCaseAndCanonicalUnicodeWithoutRemovingAccents() {
    #expect(NameKey.make("  CAFÉ\n") == NameKey.make("cafe\u{301}"))
    #expect(NameKey.make("Straße") == NameKey.make("STRASSE"))
    #expect(NameKey.make("café") != NameKey.make("cafe"))
    #expect(NameKey.make("A B") != NameKey.make("AB"))
    #expect(NameKey.make(" \n\t") == "")
}

@Test func intervalsAreHalfOpenAndIntersectSymmetrically() throws {
    let first = try EntryInterval(startAt: 10, endAt: 20)
    let adjacent = try EntryInterval(startAt: 20, endAt: 30)
    let crossing = try EntryInterval(startAt: 15, endAt: 25)
    #expect(first.durationSeconds == 10)
    #expect(!first.overlaps(adjacent))
    #expect(!adjacent.overlaps(first))
    #expect(first.intersection(adjacent) == nil)
    #expect(first.overlaps(first))
    #expect(first.intersection(first) == first)
    #expect(first.intersection(crossing) == (try EntryInterval(startAt: 15, endAt: 20)))
    #expect(first.intersection(crossing) == crossing.intersection(first))
}

@Test func intervalsRejectInvalidDurationWithoutOverflow() throws {
    #expect(throws: IntervalError.nonPositiveDuration) { try EntryInterval(startAt: 1, endAt: 1) }
    #expect(throws: IntervalError.nonPositiveDuration) { try EntryInterval(startAt: 2, endAt: 1) }
    #expect(throws: IntervalError.durationOverflow) { try EntryInterval(startAt: .min, endAt: .max) }
    let negativeEpoch = try EntryInterval(startAt: -10, endAt: 0)
    #expect(negativeEpoch.durationSeconds == 10)
    let largest = try EntryInterval(startAt: 0, endAt: .max)
    #expect(largest.durationSeconds == .max)
}
