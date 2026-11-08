import Foundation
import Testing
@testable import LibraryStore

@Suite struct ValidationTests {
    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
    }

    private var project: Project {
        Project(id: id(1), name: "Client", hourlyRate: 100, currencyCode: "EUR")
    }

    private func task(_ value: Int = 2, projectID: UUID? = nil, parent: Int? = nil,
                      name: String = "Work", budget: Int64? = nil,
                      warning: WarningThreshold = .none) -> TaskRecord {
        TaskRecord(id: id(value), projectID: projectID ?? project.id,
                   parentTaskID: parent.map(id), name: name, budgetSeconds: budget,
                   lastWarnedThreshold: warning)
    }

    private func entry(_ value: Int = 10, owner: Int = 2, start: Int64 = 0,
                       end: Int64? = 10) -> TimeEntry {
        TimeEntry(id: id(value), taskID: id(owner), startAt: start, endAt: end)
    }

    private func pending(_ value: Int = 20, owner: Int = 2, start: Int64 = 0,
                         end: Int64? = 10) -> PendingSleepInterval {
        PendingSleepInterval(id: id(value), taskID: id(owner), sleepAt: start, wakeAt: end)
    }

    private func snapshot(version: Int64 = 1, revision: Int64 = 0, projects: [Project]? = nil,
                          tasks: [TaskRecord]? = nil, entries: [TimeEntry] = [],
                          timer: ActiveTimer? = nil,
                          sleep: [PendingSleepInterval] = []) -> LibrarySnapshot {
        LibrarySnapshot(schemaVersion: version, revision: revision, projects: projects ?? [project],
                        tasks: tasks ?? [task()], entries: entries, activeTimer: timer,
                        pendingSleepIntervals: sleep)
    }

    private func errors(_ value: LibrarySnapshot, now: Int64? = nil) -> [Violation] {
        SnapshotValidator.violations(in: value, now: now)
    }

    @Test func emptyOrdinaryAndThrowingEquivalence() throws {
        let values = [snapshot(projects: [], tasks: []), snapshot(),
                      snapshot(entries: [entry()]), snapshot(version: 2, revision: -1),
                      snapshot(tasks: [task(name: " ")])]
        for value in values {
            let found = errors(value)
            if found.isEmpty { try SnapshotValidator.validate(value) }
            else {
                #expect(throws: LibraryError.invalid(found)) { try SnapshotValidator.validate(value) }
            }
        }
        #expect(errors(values[0]).isEmpty)
        #expect(errors(values[1]).isEmpty)
        #expect(errors(values[2]).isEmpty)
        #expect(errors(values[3]) == [Violation(.metadata)])
    }

    @Test func duplicateCollectionsFailBeforeAnyOtherStage() {
        let p = project, t = task(), e = entry(), s = pending()
        let values = [snapshot(version: 9, projects: [p, p]), snapshot(tasks: [t, t]),
                      snapshot(entries: [e, e]), snapshot(sleep: [s, s])]
        for value in values { #expect(errors(value) == [Violation(.duplicateID)]) }
        // IDs are scoped to a collection, not a whole snapshot.
        #expect(errors(snapshot(tasks: [task(1)], entries: [entry(1, owner: 1)],
                                sleep: [pending(1, owner: 1)])).isEmpty)
    }

    @Test func projectAndTaskFields() {
        for name in ["", " Work", "Work\n", "A\0B"] {
            #expect(errors(snapshot(tasks: [task(name: name)])) == [Violation(.task, id(2))])
            let p = Project(id: id(1), name: name, hourlyRate: 0, currencyCode: "EUR")
            #expect(errors(snapshot(projects: [p])) == [Violation(.project, id(1))])
        }
        for rate in [Decimal(-1), Decimal.nan] {
            let p = Project(id: id(1), name: "Client", hourlyRate: rate, currencyCode: "EUR")
            #expect(errors(snapshot(projects: [p])) == [Violation(.project, id(1))])
        }
        for currency in ["eur", "XYZ", "", "EUR\0"] {
            let p = Project(id: id(1), name: "Client", hourlyRate: 0, currencyCode: currency)
            #expect(errors(snapshot(projects: [p])) == [Violation(.project, id(1))])
        }
        #expect(errors(snapshot(projects: [Project(id: id(1), name: "Client", hourlyRate: 0,
                                                   currencyCode: "EUR")])).isEmpty)
        for budget: Int64 in [0, -1] {
            #expect(errors(snapshot(tasks: [task(budget: budget)])) == [Violation(.task, id(2))])
        }
        #expect(errors(snapshot(tasks: [task(projectID: id(999))])) == [Violation(.task, id(2))])
        let second = Project(id: id(5), name: project.name, hourlyRate: 1, currencyCode: "USD")
        #expect(errors(snapshot(projects: [project, second])).isEmpty)
    }

    @Test func hierarchyAndStructuralShortCircuit() {
        for tasks in [[task(parent: 999)], [task(parent: 2)],
                      [task(parent: 3), task(3, projectID: id(5))]] {
            let second = Project(id: id(5), name: "Other", hourlyRate: 0, currencyCode: "EUR")
            #expect(errors(snapshot(projects: [project, second], tasks: tasks,
                                    entries: [entry(owner: 999, end: 0)])) == [Violation(.hierarchy, id(2))])
        }
        let cycle = [task(parent: 3), task(3, parent: 4), task(4, parent: 2), task(5, parent: 2, name: "Branch")]
        #expect(errors(snapshot(tasks: cycle)) == [2, 3, 4].map { Violation(.hierarchy, id($0)) })
        #expect(errors(snapshot(tasks: [task(budget: 0)], entries: [entry(end: 0)],
                                sleep: [pending(owner: 999)])) == [Violation(.task, id(2))])
    }

    @Test func arbitraryDepthIsIterative() {
        let tasks = (2...5001).map { task($0, parent: $0 == 2 ? nil : $0 - 1) }
        #expect(errors(snapshot(tasks: tasks, entries: [entry(owner: 5001)])).isEmpty)
        var cyclic = tasks
        cyclic[0] = task(2, parent: 5001)
        let found = errors(snapshot(tasks: cyclic))
        #expect(found.count == 5000)
        #expect(found.allSatisfy { $0.code == .hierarchy })
    }

    @Test func unicodeGroupsAndPermutationStability() {
        let tasks = [task(2, name: "CAFÉ"), task(3, name: "cafe\u{301}"), task(4, name: "cafe"),
                     task(5, name: "Straße"), task(6, name: "STRASSE"),
                     task(7, parent: 4, name: "CAFÉ")]
        let expected = [2, 3, 5, 6].map { Violation(.siblingName, id($0)) }
        #expect(errors(snapshot(tasks: tasks)) == expected)
        #expect(errors(snapshot(tasks: tasks.reversed())) == expected)
        let rows = [entry(10, start: 0, end: 100), entry(11, start: 0, end: 10),
                    entry(12, start: 20, end: 30), entry(13, start: 100, end: 110)]
        let value = snapshot(version: 2, entries: rows, sleep: [pending(20, end: 0), pending(21, end: 0)])
        let reversed = snapshot(version: 2, entries: rows.reversed(),
                                sleep: [pending(21, end: 0), pending(20, end: 0)])
        #expect(errors(value) == errors(reversed))
        #expect(errors(value) == [Violation(.metadata), Violation(.overlap, id(11)),
                                  Violation(.overlap, id(12)), Violation(.pending, id(20)),
                                  Violation(.pending, id(21))])
        let other = Project(id: id(50), name: "Other", hourlyRate: -1, currencyCode: "eur")
        #expect(errors(snapshot(projects: [project, other])) == errors(snapshot(projects: [other, project])))
    }

    @Test func ownershipMissingAndNonLeaf() {
        let tasks = [task(), task(3, parent: 2)]
        #expect(errors(snapshot(tasks: tasks, entries: [entry(), entry(11, owner: 999, start: 10, end: 20)],
                                sleep: [pending(), pending(21, owner: 999)])) ==
                [Violation(.ownership, id(10)), Violation(.ownership, id(11)),
                 Violation(.ownership, id(20)), Violation(.ownership, id(21))])
    }

    @Test func intervalBoundariesOverflowAndGlobalOverlap() {
        for row in [entry(end: 0), entry(start: 10, end: 9), entry(start: .min, end: .max)] {
            #expect(errors(snapshot(entries: [row])) == [Violation(.interval, id(10))])
        }
        #expect(errors(snapshot(entries: [entry(start: -10, end: 0), entry(11, start: 0, end: 10)])).isEmpty)
        #expect(errors(snapshot(entries: [entry(start: 0, end: .max)])).isEmpty)
        let other = Project(id: id(50), name: "Other", hourlyRate: 0, currencyCode: "USD")
        let value = snapshot(projects: [project, other], tasks: [task(), task(3, projectID: id(50))],
                             entries: [entry(), entry(11, owner: 3, start: 9, end: 11)])
        #expect(errors(value) == [Violation(.overlap, id(11))])
        #expect(errors(snapshot(entries: [entry(end: 0)]), now: -1) == [Violation(.interval, id(10))])
    }

    @Test func timerShapesCheckpointBoundsAndReservedTail() {
        let open = entry(start: 10, end: nil)
        let timer = ActiveTimer(entryID: open.id, checkpointAt: 20)
        #expect(errors(snapshot(entries: [open], timer: timer)).isEmpty)
        #expect(errors(snapshot(entries: [open], timer: ActiveTimer(entryID: open.id, checkpointAt: 10))).isEmpty)
        #expect(errors(snapshot(entries: [open])) == [Violation(.timer)])
        #expect(errors(snapshot(timer: timer)) == [Violation(.timer)])
        #expect(errors(snapshot(entries: [open], timer: ActiveTimer(entryID: id(99), checkpointAt: 20))) ==
                [Violation(.timer)])
        #expect(errors(snapshot(entries: [open, entry(11, start: 20, end: nil)], timer: timer)) == [Violation(.timer)])
        for checkpoint: Int64 in [9, .min] {
            #expect(errors(snapshot(entries: [open], timer: ActiveTimer(entryID: open.id, checkpointAt: checkpoint))) ==
                    [Violation(.timer, open.id)])
        }
        let overflow = entry(start: .min, end: nil)
        #expect(errors(snapshot(entries: [overflow], timer: ActiveTimer(entryID: overflow.id, checkpointAt: .max))) ==
                [Violation(.timer, overflow.id)])
        let archived = Project(id: project.id, name: project.name, hourlyRate: 0,
                               currencyCode: "EUR", isArchived: true)
        #expect(errors(snapshot(projects: [archived], entries: [open], timer: timer)) == [Violation(.timer, open.id)])
        #expect(errors(snapshot(projects: [archived], entries: [entry()])).isEmpty)
        #expect(errors(snapshot(entries: [entry(11, end: 10), open], timer: timer)).isEmpty)
        #expect(errors(snapshot(entries: [open, entry(11, start: 100, end: 110)], timer: timer)) ==
                [Violation(.overlap, open.id)])
    }

    @Test func callerClockDoesNotInvalidateDurableActiveOrSleep() {
        let open = entry(11, start: 10, end: nil)
        let value = snapshot(entries: [entry(), open], timer: ActiveTimer(entryID: open.id, checkpointAt: 100),
                             sleep: [pending(start: 200, end: 300)])
        #expect(errors(value).isEmpty)
        #expect(errors(value, now: 5) == [Violation(.interval, id(10))])
        #expect(errors(value, now: 10).isEmpty)
    }

    @Test func pendingKnownUnknownAndUnbilled() {
        for row in [pending(end: 0), pending(start: 10, end: 9), pending(start: .min, end: .max)] {
            #expect(errors(snapshot(sleep: [row])) == [Violation(.pending, id(20))])
        }
        #expect(errors(snapshot(entries: [entry()], sleep: [pending(), pending(21, end: nil)])).isEmpty)
        #expect(errors(snapshot(sleep: [pending(end: nil), pending(21, end: nil)])) == [Violation(.pending)])
        let open = entry(end: nil)
        #expect(errors(snapshot(entries: [open], timer: ActiveTimer(entryID: open.id, checkpointAt: 0),
                                sleep: [pending(end: nil)])) == [Violation(.pending)])
        #expect(errors(snapshot(tasks: [task(budget: 10)], sleep: [pending(end: 100)])).isEmpty)
    }

    @Test func frontierEqualityExcessAndNearestBudgetStops() {
        let tasks = [task(budget: 100), task(3, parent: 2), task(4, parent: 3, budget: 60),
                     task(5, parent: 2, name: "Other", budget: 40), task(6, parent: 4, budget: 60)]
        #expect(errors(snapshot(tasks: tasks)).isEmpty)
        var excess = tasks
        excess[0] = task(budget: 99)
        #expect(errors(snapshot(tasks: excess)) == [Violation(.allocation, id(2))])
        let large = [task(budget: .max), task(3, parent: 2, budget: .max),
                     task(4, parent: 2, name: "Other", budget: .max)]
        #expect(errors(snapshot(tasks: large)) == [Violation(.allocation, id(2))])
    }

    @Test func exactWarningBandsRollupAndRearming() {
        for (seconds, band): (Int64, WarningThreshold) in [(79, .none), (80, .eighty), (99, .eighty),
                                                         (100, .hundred), (101, .hundred)] {
            let tasks = [task(budget: 100, warning: band), task(3, parent: 2, budget: 100, warning: band)]
            #expect(errors(snapshot(tasks: tasks, entries: [entry(owner: 3, end: seconds)])).isEmpty)
        }
        #expect(errors(snapshot(tasks: [task(budget: 100, warning: .hundred)], entries: [entry(end: 79)])) ==
                [Violation(.warning, id(2))])
        #expect(errors(snapshot(tasks: [task(warning: .eighty)])) == [Violation(.warning, id(2))])
        #expect(errors(snapshot(tasks: [task(budget: 1)], entries: [])).isEmpty)
        #expect(errors(snapshot(tasks: [task(budget: 1, warning: .hundred)], entries: [entry(end: 1)])).isEmpty)
        let threshold = Int64.max / 5 * 4 + 2
        #expect(errors(snapshot(tasks: [task(budget: .max)], entries: [entry(end: threshold - 1)])).isEmpty)
        #expect(errors(snapshot(tasks: [task(budget: .max, warning: .eighty)],
                                entries: [entry(end: threshold)])).isEmpty)
        // Accumulation exceeds Int64 without wrapping.
        #expect(errors(snapshot(tasks: [task(budget: .max, warning: .hundred)],
                                entries: [entry(start: .min, end: -1), entry(11, start: -1, end: .max - 1)])).isEmpty)
    }

    @Test func onlyDurableCheckpointPrefixCounts() {
        let open = entry(start: 0, end: nil)
        for (checkpoint, band): (Int64, WarningThreshold) in [(0, .none), (79, .none), (80, .eighty), (100, .hundred)] {
            #expect(errors(snapshot(tasks: [task(budget: 100, warning: band)], entries: [open],
                                    timer: ActiveTimer(entryID: open.id, checkpointAt: checkpoint)), now: 1000).isEmpty)
        }
        #expect(errors(snapshot(tasks: [task(budget: 100, warning: .hundred)], entries: [open],
                                timer: ActiveTimer(entryID: open.id, checkpointAt: 80))) == [Violation(.warning, id(2))])
    }
}
