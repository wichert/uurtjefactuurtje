import Foundation
import Testing

@testable import LibraryStore
@testable import UurtjeFactuurtje

@Suite @MainActor struct ContextualTaskBudgetTests {

    private func draft(minutes: Int64?, locale: Locale, isNew: Bool = false) -> TaskDraft {
        let text = minutes.map { BudgetInput.text($0, locale: locale) } ?? ""
        return TaskDraft(
            id: UUID(), isNew: isNew, observedRevision: 0,
            projectID: UUID(), parentID: nil, name: "Draft", migrationAccepted: false,
            budgetEnabled: minutes != nil, budgetHours: text,
            originalBudgetMinutes: minutes, originalBudgetText: text)
    }

    @Test func roundedGeneratedStepsStayExactAcrossLocalesAndManualChanges() {
        for locale in [Locale(identifier: "en_US"), Locale(identifier: "nl_NL")] {
            var directory = draft(minutes: 1, locale: locale)
            #expect(BudgetInput.parseHours(directory.budgetHours, locale: locale) == nil)
            #expect(directory.budgetValue(locale: locale) == 1)
            #expect(directory.budgetAfterStep(by: -30, locale: locale) == nil)
            let original = directory.budgetHours
            directory.stepBudget(by: -30, locale: locale)
            #expect(directory.budgetHours == original)
            directory.stepBudget(by: 30, locale: locale)
            #expect(directory.budgetHours == BudgetInput.text(31, locale: locale))
            #expect(directory.generatedBudgetMinutes == 31)
            #expect(BudgetInput.parseHours(directory.budgetHours, locale: locale) == nil)
            #expect(directory.budgetValue(locale: locale) == 31)
            directory.stepBudget(by: 30, locale: locale)
            #expect(directory.budgetValue(locale: locale) == 61)
            directory.stepBudget(by: -30, locale: locale)
            directory.stepBudget(by: -30, locale: locale)
            #expect(directory.budgetValue(locale: locale) == 1)
            directory.budgetHours = "not hours"
            #expect(directory.budgetValue(locale: locale) == nil)
            #expect(directory.budgetAfterStep(by: 30, locale: locale) == nil)
            directory.stepBudget(by: 30, locale: locale)
            #expect(directory.budgetHours == "not hours")
            directory.budgetHours = "1\(locale.decimalSeparator!)5"
            #expect(directory.budgetValue(locale: locale) == 90)
            directory.stepBudget(by: 30, locale: locale)
            #expect(directory.budgetValue(locale: locale) == 120)
            directory.budgetEnabled = false
            #expect(directory.budgetValue(locale: locale) == nil)
            #expect(directory.budgetAfterStep(by: 30, locale: locale) == nil)
            directory.budgetEnabled = true
            #expect(directory.budgetValue(locale: locale) == 120)
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
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let leaf = try await task(track, project: projectID)
            for isNew in [true, false] {
                if isNew { track.newTask(projectID: projectID) } else { track.editTask(leaf) }
                guard case .task(var directory) = track.sheet else {
                    Issue.record("Missing draft")
                    return
                }
                directory.name = "Valid name"
                let seconds = try #require(track.workspace.snapshot)
                directory.budgetEnabled = true
                for invalid in ["", "0", "-1", "garbage", "0\(Locale.current.decimalSeparator ?? ".")001"] {
                    directory.budgetHours = invalid
                    #expect(
                        directory.inputError(in: seconds)
                            == "Enter positive budget hours that represent timer whole number of minutes.")
                }
                directory.budgetEnabled = false
                #expect(directory.inputError(in: seconds) == nil)
                #expect(directory.request(start: false).budgetMinutes == nil)
                directory.budgetEnabled = true
                directory.budgetHours = "2"
                #expect(directory.inputError(in: seconds) == nil)
                #expect(directory.parsedBudget == 120)
                #expect(track.workspace.snapshot == seconds)
                track.cancelSheet()
            }
        }
    }

    @Test func contextualCreationCarriesBudgetForBothCommandsAndBudgetCanBeCleared() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let root = try await task(track, project: projectID, name: "Root")
            for start in [false, true] {
                track.newTask(projectID: projectID, parentID: root)
                guard case .task(var directory) = track.sheet else {
                    Issue.record("Missing new task")
                    return
                }
                #expect(
                    !directory.budgetEnabled && directory.budgetHours.isEmpty
                        && directory.originalBudgetMinutes == nil)
                #expect(directory.projectID == projectID && directory.parentID == root)
                directory.name = start ? "Running" : "Saved"
                directory.budgetEnabled = true
                directory.stepBudget(by: 30)
                let seconds = try #require(track.workspace.snapshot)
                #expect(directory.inputError(in: seconds) == nil)
                let request = directory.request(start: start)
                #expect(
                    request.id == directory.id && request.projectID == projectID && request.parentID == root)
                #expect(request.budgetMinutes == 30 && request.start == start)
                let created = try await track.workspace.enqueueTaskCreation(
                    request, expectedRevision: directory.observedRevision,
                    reviewedSnapshot: directory.reviewedSnapshot
                ).value
                #expect(created.snapshot.tasks.first(where: { $0.id == directory.id })?.budgetMinutes == 30)
                if start {
                    let active = try #require(created.snapshot.activeTimer)
                    #expect(
                        created.snapshot.entries.first(where: { $0.id == active.entryID })?.taskID
                            == directory.id)
                    _ = try await track.workspace.enqueueTimer(.stop(expectedEntryID: active.entryID)).value
                } else {
                    #expect(created.snapshot.activeTimer == nil)
                }
                track.cancelSheet()
                try await verifyBudgetCanBeCleared(track: track, taskID: directory.id)
            }
        }
    }

    private func verifyBudgetCanBeCleared(track: TrackPresentation, taskID: UUID) async throws {
        track.editTask(taskID)
        guard case .task(var edit) = track.sheet else {
            Issue.record("Missing edit")
            return
        }
        #expect(edit.originalBudgetMinutes == 30 && edit.parsedBudget == 30)
        edit.budgetEnabled = false
        let latest = try #require(track.workspace.snapshot)
        _ = try await track.workspace.enqueueSubmit(
            .editTask(id: edit.id, name: edit.name, budgetMinutes: edit.parsedBudget),
            expectedRevision: latest.revision, reviewedSnapshot: edit.reviewedSnapshot
        ).value
        #expect(
            track.workspace.snapshot?.tasks.first(where: { $0.id == edit.id })?.budgetMinutes == nil)
        track.cancelSheet()
    }

    @Test func budgetedMigrationStillRequiresConsentAndKeepsGenericBudgetless() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let parent = try await task(track, project: projectID)
            let before = try #require(track.workspace.snapshot)
            let preview = try CorrectionPlanner.preview(
                .add(id: UUID(), taskID: parent, startAt: 100, endAt: 200), in: before)
            _ = try await track.workspace.enqueueCorrection(.apply(preview)).value
            track.newTask(projectID: projectID, parentID: parent)
            guard case .task(var directory) = track.sheet else {
                Issue.record("Missing draft")
                return
            }
            directory.name = "Budgeted child"
            directory.budgetEnabled = true
            directory.budgetHours = "2"
            let seconds = try #require(track.workspace.snapshot)
            do {
                _ = try await track.workspace.enqueueTaskCreation(
                    directory.request(start: false), expectedRevision: directory.observedRevision,
                    reviewedSnapshot: directory.reviewedSnapshot
                ).value
                Issue.record("Unconfirmed budgeted migration succeeded")
            } catch { #expect(track.workspace.snapshot == seconds) }
            directory.migrationAccepted = true
            let result = try await track.workspace.enqueueTaskCreation(
                directory.request(start: false), expectedRevision: directory.observedRevision,
                reviewedSnapshot: directory.reviewedSnapshot
            ).value
            let generic = try #require(result.genericID)
            #expect(result.movedEntryCount == 1)
            #expect(result.snapshot.tasks.first(where: { $0.id == directory.id })?.budgetMinutes == 120)
            #expect(result.snapshot.tasks.first(where: { $0.id == generic })?.budgetMinutes == nil)
            #expect(result.snapshot.entries.first?.taskID == generic)
        }
    }

    @Test func allowanceIsMinuteExactAndOverBudgetCreationDoesNotCommit() async throws {
        try await withTrack { track, _ in
            let projectID = try await project(track)
            let root = try await task(track, project: projectID, name: "Root")
            let sibling = try await task(track, project: projectID, parent: root, name: "Sibling")
            var seconds = try #require(track.workspace.snapshot)
            _ = try await track.workspace.enqueueSubmit(
                .editTask(id: root, name: "Root", budgetMinutes: 120), expectedRevision: seconds.revision
            ).value
            seconds = try #require(track.workspace.snapshot)
            _ = try await track.workspace.enqueueSubmit(
                .editTask(id: sibling, name: "Sibling", budgetMinutes: 90),
                expectedRevision: seconds.revision
            ).value
            track.newTask(projectID: projectID, parentID: root)
            guard case .task(var directory) = track.sheet else {
                Issue.record("Missing draft")
                return
            }
            directory.name = "Too much"
            directory.budgetEnabled = true
            directory.budgetHours = "1"
            seconds = try #require(track.workspace.snapshot)
            let allowance = try BudgetRules.allowance(
                in: seconds, projectID: projectID, parentTaskID: root, editingTaskID: nil)
            #expect(allowance.minimumMinutes == 0 && allowance.maximumMinutes == 30)
            #expect(allowance.limitingAncestorID == root)
            do {
                _ = try await track.workspace.enqueueTaskCreation(
                    directory.request(start: false), expectedRevision: directory.observedRevision,
                    reviewedSnapshot: directory.reviewedSnapshot
                ).value
                Issue.record("Over-budget creation succeeded")
            } catch {
                guard case CommandError.budgetAllocation(let id, let returned) = error else { throw error }
                #expect(id == directory.id && returned == allowance)
                #expect(track.workspace.snapshot == seconds)
            }
        }
    }

}
