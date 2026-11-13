import AppKit
import Foundation
import SwiftUI
import Testing
import UserNotifications

@testable import LibraryStore
@testable import UurtjeFactuurtje

extension NativeHostTests {
    private struct RejectedQuitContext {
        let token: UUID
        let id: UUID
        let before: LibrarySnapshot
        let setting: Task<Void, Error>
    }

    private struct SleepQuitContext {
        let token: UUID
        let id: UUID
        let before: LibrarySnapshot?
        let projectID: UUID
    }

    private struct CloseCounters {
        var replies: Int
        var closes: Int
        var opens: Int
    }

    @Test func quitDrainsStopsClosesAndRepliesOnce() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            let clock = NativeClock()
            track.workspace.configureTimer(clock: { clock.read() })
            let projectID = try await project(track)
            let id = try await task(track, project: projectID)
            let lifecycle = Lifecycle(host: host)
            var events: [String] = []
            lifecycle.confirmQuit = {
                events.append("confirm")
                clock.set(110)
                return true
            }
            lifecycle.close = { model in
                #expect(model.snapshot?.activeTimer == nil)
                #expect(model.snapshot?.entries.last?.taskID == id)
                events.append("close")
                await model.close()
            }
            await withCheckedContinuation { done in
                lifecycle.reply = { permitted in
                    #expect(permitted)
                    events.append("reply")
                    done.resume()
                }
                host.submitTimer(.start(taskID: id))  // Accepted FIFO work precedes quit.
                lifecycle.requestQuit()
                #expect(!host.acceptingMutations)
                host.submitTimer(.start(taskID: UUID()))
                lifecycle.checkpointTick()
                lifecycle.budgetTick()
                lifecycle.requestQuit()
            }
            #expect(events == ["confirm", "close", "reply"])
            #expect(track.workspace.availability == .closed)
            host.invalidate()
        }
    }

    @Test func quitRejectsDirectCallbacksWhileAcceptedWorkDrains() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            let projectID = try await project(track)
            let id = try await task(track, project: projectID)
            let gate = NativeSubmissionGate()
            track.workspace.configureTimer(
                clock: { 100 },
                write: { library, command, revision, instant, entry in
                    await gate.pause()
                    return try await library.performTimer(
                        command, expectedRevision: revision, instant: instant, newEntryID: entry)
                })
            host.track.editProject(projectID)
            let token = host.track.routeToken
            #expect(host.track.begin(token))
            let before = try #require(track.workspace.snapshot)
            host.submitTimer(.start(taskID: id))
            await gate.waitForArrival()
            let setting = try #require(host.submitFirstWeekday(4))
            let editor = track.workspace.enqueueSubmit(
                .renameTask(id: id, name: "Accepted"), expectedRevision: before.revision + 1)
            host.retain(
                Task { @MainActor in
                    do {
                        _ = try await editor.value
                        host.track.complete(token)
                    } catch {
                        host.track.complete(token, error: error)
                        Issue.record("Accepted editor failed: \(error)")
                    }
                })
            try await verifyRejectedQuitCallbacks(
                track: track, host: host, gate: gate,
                context: RejectedQuitContext(token: token, id: id, before: before, setting: setting))
        }
    }

    @Test func quitRejectsCallbacksAndPreservesSleepWakeDuringConfirmation() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            let clock = NativeClock()
            track.workspace.configureTimer(clock: { clock.read() })
            let projectID = try await project(track)
            let id = try await task(track, project: projectID)
            host.submitTimer(.start(taskID: id))
            await host.drain()
            host.track.editProject(projectID)
            let token = host.track.routeToken
            let before = track.workspace.snapshot
            try await verifySleepDuringQuitConfirmation(
                track: track, host: host, clock: clock,
                context: SleepQuitContext(token: token, id: id, before: before, projectID: projectID))
        }
    }

    @Test func quitCancelStopFailureAndCloseFailureNeverReplay() async throws {
        try await withTrack { track, directory in
            let host = NativeHost(directory: directory, workspace: track.workspace)
            let clock = NativeClock()
            track.workspace.configureTimer(clock: { clock.read() })
            let projectID = try await project(track)
            let id = try await task(track, project: projectID)
            host.submitTimer(.start(taskID: id))
            await host.drain()
            let lifecycle = Lifecycle(host: host)
            var closes = 0
            var replies = 0
            var opens = 0
            host.installSceneActions(workspace: { opens += 1 }, settings: {})
            lifecycle.close = { _ in closes += 1 }
            lifecycle.confirmQuit = { false }
            await withCheckedContinuation { done in
                lifecycle.reply = { accepted in
                    #expect(!accepted)
                    replies += 1
                    done.resume()
                }
                lifecycle.requestQuit()
            }
            #expect(closes == 0)
            #expect(host.acceptingMutations)
            lifecycle.confirmQuit = { true }
            track.workspace.configureTimer(
                clock: { clock.read() }, write: { _, _, _, _, _ in throw StorageError.injectedFailure })
            await withCheckedContinuation { done in
                lifecycle.reply = { accepted in
                    #expect(!accepted)
                    replies += 1
                    done.resume()
                }
                lifecycle.requestQuit()
            }
            #expect(closes == 0)
            #expect(track.workspace.snapshot?.activeTimer != nil)
            try await verifyFailedCloseReopen(
                track: track, host: host, lifecycle: lifecycle, clock: clock,
                counters: CloseCounters(replies: replies, closes: closes, opens: opens))
        }
    }

    private func verifyRejectedQuitCallbacks(
        track: TrackPresentation, host: NativeHost, gate: NativeSubmissionGate,
        context: RejectedQuitContext
    ) async throws {
        let token = context.token
        let id = context.id
        let before = context.before
        let setting = context.setting
        let lifecycle = Lifecycle(host: host)
        lifecycle.confirmQuit = { false }
        await withCheckedContinuation { done in
            lifecycle.reply = { accepted in
                #expect(!accepted)
                done.resume()
            }
            lifecycle.requestQuit()
            #expect(!host.track.begin(token))
            host.track.timer(.stop(expectedEntryID: nil))
            host.track.undoMigration(receiptID: UUID())
            host.track.undoCorrection()
            host.track.undoTimeReview()
            #expect(host.submitFirstWeekday(5) == nil)
            #expect(host.track.acceptedWork)
            Task { await gate.release() }
        }
        try await setting.value
        await host.drain()
        #expect(track.workspace.firstWeekday == 4)
        #expect(track.workspace.snapshot?.tasks.first(where: { $0.id == id })?.name == "Accepted")
        #expect(track.workspace.snapshot?.revision == before.revision + 2)
        #expect(track.workspace.snapshot?.activeTimer != nil)
        #expect(track.workspace.issue == nil && host.track.failure == nil)
        #expect(!host.track.acceptedWork && host.acceptingMutations)
        #expect(host.track.begin(host.track.routeToken))
        host.track.complete(host.track.routeToken)
        let resumed = try #require(host.submitFirstWeekday(5))
        try await resumed.value
        #expect(track.workspace.firstWeekday == 5)
        host.invalidate()
    }

    private func verifySleepDuringQuitConfirmation(
        track: TrackPresentation, host: NativeHost, clock: NativeClock,
        context: SleepQuitContext
    ) async throws {
        let token = context.token
        let id = context.id
        let before = context.before
        let projectID = context.projectID
        let lifecycle = Lifecycle(host: host)
        let confirmation = NativeSubmissionGate()
        lifecycle.confirmQuit = {
            await confirmation.pause()
            return true
        }
        var closes = 0
        lifecycle.close = { _ in closes += 1 }
        await withCheckedContinuation { done in
            lifecycle.reply = { accepted in
                #expect(!accepted)
                done.resume()
            }
            lifecycle.requestQuit()
            Task { @MainActor in
                await confirmation.waitForArrival()
                #expect(!host.track.begin(token))
                host.track.timer(.stop(expectedEntryID: nil))
                host.track.undoMigration(receiptID: UUID())
                host.track.undoCorrection()
                host.track.undoTimeReview()
                #expect(host.submitFirstWeekday(6) == nil)
                #expect(!track.workspace.isBusy && track.workspace.snapshot == before)
                clock.set(110)
                lifecycle.willSleep()
                lifecycle.didWake(at: Date(timeIntervalSince1970: 120))
                await confirmation.release()
            }
        }
        #expect(closes == 0 && host.acceptingMutations)
        let resumed = try #require(track.workspace.snapshot?.activeTimer)
        #expect(resumed.entryID != before?.activeTimer?.entryID && resumed.checkpointAt == 120)
        #expect(
            track.workspace.snapshot?.entries.first(where: { $0.id == resumed.entryID })?.taskID == id)
        #expect(
            track.workspace.snapshot?.entries.first(where: { $0.id == before?.activeTimer?.entryID })?
                .endAt == 110)
        #expect(track.workspace.snapshot?.pendingSleepIntervals.first?.sleepAt == 110)
        #expect(track.workspace.snapshot?.pendingSleepIntervals.first?.wakeAt == 120)
        #expect(host.track.sheet?.id == projectID && !host.track.acceptedWork)
        #expect(host.track.begin(token))
        host.track.complete(token)
        host.invalidate()
    }

    private func verifyFailedCloseReopen(
        track: TrackPresentation, host: NativeHost, lifecycle: Lifecycle, clock: NativeClock,
        counters: CloseCounters
    ) async throws {
        var counters = counters
        var replies = counters.replies
        var closes = counters.closes
        clock.set(110)
        track.workspace.configureTimer(
            clock: { clock.read() },
            write: { library, command, revision, instant, entry in
                try await library.performTimer(
                    command, expectedRevision: revision, instant: instant, newEntryID: entry)
            })
        lifecycle.close = { model in
            closes += 1
            await model.close()
            throw LibraryAccessError.unavailable
        }
        host.installSceneActions(workspace: { counters.opens += 1 }, settings: {})
        await withCheckedContinuation { done in
            lifecycle.reply = { accepted in
                #expect(!accepted)
                replies += 1
                done.resume()
            }
            lifecycle.requestQuit()
        }
        #expect(replies == 3)
        #expect(closes == 1)
        #expect(counters.opens > 0)
        #expect(!host.acceptingMutations)
        #expect(!host.recoveryDetails.isEmpty)
        host.reopen()
        await host.drain()
        #expect(host.acceptingMutations)
        #expect(track.workspace.snapshot?.activeTimer != nil)
        #expect(track.workspace.snapshot?.entries.last?.endAt == nil)  // Paused timer is left unchanged for review.
        host.invalidate()
    }

}
