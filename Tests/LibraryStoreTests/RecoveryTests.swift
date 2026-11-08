import Foundation
import Darwin
import SQLite3
import Testing
import XCTest
@testable import LibraryStore

private enum RecoveryTestError: Error { case injected }

private func temporaryLibrary() -> URL {
    URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path, isDirectory: true)
        .appendingPathComponent("uf-recovery-" + UUID().uuidString)
}

private func expectFailure<T>(_ operation: () async throws -> T) async {
    do { _ = try await operation(); Issue.record("expected failure") }
    catch { }
}

private func populated(_ root: URL) async throws {
    let library = try await Library.open(at: root)
    _ = try await addProject(library, revision: 0)
    await library.close()
}

@discardableResult
private func addProject(_ library: Library, revision: Int64) async throws -> Committed<UUID> {
    let id = UUID()
    return try await library.transact(expectedRevision: revision) { storage, _ in
        try storage.runCommand("INSERT INTO projects VALUES (?,?,?,?,?)", bindings: [
            .text(id.uuidString.lowercased()), .text("Client"), .text("12"), .text("EUR"), .integer(0)
        ], expectedChanges: 1)
        return id
    }
}

// A separate XCTest process supplies real abrupt death without killing the test runner.
final class RecoveryCrashProbe: XCTestCase {
    func testProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["UF_RECOVERY_ROOT"] else { return }
        let root = URL(fileURLWithPath: directory)
        switch env["UF_RECOVERY_ACTION"] {
        case "busy":
            do { let owner = try await Library.open(at: root); await owner.close(); Darwin._exit(91) }
            catch LibraryOpenError.busy { Darwin._exit(90) }
            catch { Darwin._exit(92) }
        case "hot":
            var database: OpaquePointer?
            guard sqlite3_open(root.appendingPathComponent("library.sqlite").path, &database) == SQLITE_OK else {
                Darwin._exit(93)
            }
            let statement = "PRAGMA journal_mode=DELETE; PRAGMA cache_size=1; PRAGMA cache_spill=ON; BEGIN IMMEDIATE;"
            guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else { Darwin._exit(94) }
            for index in 0..<3000 {
                let command = "INSERT INTO projects VALUES ('\(UUID().uuidString.lowercased())','\(String(repeating: "X", count: 250))\(index)','12','EUR',0)"
                guard sqlite3_exec(database, command, nil, nil, nil) == SQLITE_OK else { Darwin._exit(95) }
            }
            Darwin._exit(85)
        case "crash", "mutation", "settings":
            let target = env["UF_RECOVERY_POINT"]!
            let mutation = env["UF_RECOVERY_ACTION"] == "mutation"
            let preferences = env["UF_RECOVERY_ACTION"] == "settings"
            // Mutation/settings hooks are installed only after initial open/recovery.
            let armed = FaultSwitch()
            let hooks = RecoveryHooks(recovery: { point in
                if (!mutation && !preferences || armed.enabled), point.rawValue == target { Darwin._exit(86) }
            }, io: { point in
                if armed.enabled, point.rawValue == target { Darwin._exit(86) }
            })
            do {
                let library = try await Library.open(at: root, hooks: hooks)
                armed.enable()
                if mutation { _ = try await addProject(library, revision: try await library.snapshot().revision) }
                if preferences { _ = try await library.setFirstWeekday(7) }
                await library.close()
                Darwin._exit(87)
            } catch { Darwin._exit(88) }
        default: return
        }
    }
}

private final class FaultSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    var enabled: Bool { lock.withLock { armed } }
    func enable() { lock.withLock { armed = true } }
}

private func subprocess(_ root: URL, action: String, point: String = "") throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["xctest", "-XCTest", "LibraryStoreTests.RecoveryCrashProbe/testProbe",
                         Bundle(for: RecoveryCrashProbe.self).bundleURL.path]
    var environment = ProcessInfo.processInfo.environment
    environment["UF_RECOVERY_ROOT"] = root.path
    environment["UF_RECOVERY_ACTION"] = action
    environment["UF_RECOVERY_POINT"] = point
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private func hotJournal(_ root: URL, invalidOriginal: Bool = false) async throws {
    let library = try await Library.open(at: root)
    if invalidOriginal { _ = try await addProject(library, revision: 0) }
    await library.close()
    let main = root.appendingPathComponent("library.sqlite")
    if invalidOriginal {
        var database: OpaquePointer?
        try #require(sqlite3_open(main.path, &database) == SQLITE_OK)
        let result = sqlite3_exec(database, "UPDATE projects SET currency_code = 'ZZZ'", nil, nil, nil)
        let closed = sqlite3_close(database)
        try #require(result == SQLITE_OK && closed == SQLITE_OK)
    }
    let before = try Data(contentsOf: main)
    try #require(subprocess(root, action: "hot") == 85)
    #expect(try Data(contentsOf: main) != before)
    let journal = try Data(contentsOf: root.appendingPathComponent("library.sqlite-journal"))
    #expect(journal.prefix(8) == Data([0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7]))
}

@Suite(.serialized)
struct RecoveryTests {
    @Test func directoryCreationTerminatesAndLibraryReopens() async throws {
        let root = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = RecoveryFiles(hooks: RecoveryHooks())
        let existing = root.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try files.ensureDirectory(existing)
        let nested = existing.appendingPathComponent("missing/nested", isDirectory: true)
        try files.ensureDirectory(nested)
        try files.ensureDirectory(nested)
        let owner = try await Library.open(at: nested)
        #expect(try await owner.snapshot().revision == 0)
        await owner.close()
        let reopened = try await Library.open(at: nested)
        #expect(try await reopened.snapshot().revision == 0)
        await reopened.close()
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
        #expect(throws: LibraryOpenError.self) {
            try files.ensureDirectory(link.appendingPathComponent("unsafe"))
        }
        #expect(!FileManager.default.fileExists(atPath: existing.appendingPathComponent("unsafe").path))
    }

    @Test func repeatedPublishedCommitsAndSettingsSurviveReopen() async throws {
        let root = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await Library.open(at: root)
        #expect(try await library.snapshot().revision == 0)
        #expect(try await library.settings().firstWeekday == 2)
        let first = try await addProject(library, revision: 0)
        let canonical = try Data(contentsOf: root.appendingPathComponent("library.sqlite"))
        _ = try await library.setFirstWeekday(7)
        #expect(try Data(contentsOf: root.appendingPathComponent("library.sqlite")) == canonical)
        await expectFailure { try await addProject(library, revision: 0) }
        #expect(try await library.snapshot() == first.snapshot)
        _ = try await addProject(library, revision: 1)
        await library.close()
        let reopened = try await Library.open(at: root)
        #expect(try await reopened.snapshot().revision == 2)
        #expect(try await reopened.snapshot().projects.count == 2)
        #expect(try await reopened.settings().firstWeekday == 7)
        await reopened.close()
        for day in 1...7 {
            let owner = try await Library.open(at: root)
            _ = try await owner.setFirstWeekday(day)
            await owner.close()
            let next = try await Library.open(at: root)
            #expect(try await next.settings().firstWeekday == day)
            #expect(try await next.snapshot().revision == 2)
            await next.close()
        }
    }

    @Test func stableLockAndCrossProcessExclusion() async throws {
        let root = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await Library.open(at: root)
        let path = root.appendingPathComponent(".library-lock").path
        var before = stat()
        try #require(lstat(path, &before) == 0)
        await #expect(throws: LibraryOpenError.busy) { try await Library.open(at: root) }
        #expect(try subprocess(root, action: "busy") == 90)
        await first.close()
        await first.close()
        await #expect(throws: LibraryAccessError.unavailable) { try await first.snapshot() }
        let second = try await Library.open(at: root)
        var after = stat()
        try #require(lstat(path, &after) == 0)
        #expect(before.st_ino == after.st_ino)
        await second.close()
    }

    @Test func thrownRecoveryFaultsAndCrashMatrix() async throws {
        for mode in 0...2 {
            for point in RecoveryPoint.allCases {
                for crash in [false, true] {
                    let root = temporaryLibrary()
                    defer { try? FileManager.default.removeItem(at: root) }
                    if mode == 1 { try await populated(root) }
                    if mode == 2 { try await hotJournal(root) }
                    if crash { #expect(try subprocess(root, action: "crash", point: point.rawValue) == 86) }
                    else {
                        let hooks = RecoveryHooks(recovery: { if $0 == point { throw RecoveryTestError.injected } })
                        await expectFailure { try await Library.open(at: root, hooks: hooks) }
                    }
                    let recovered = try await Library.open(at: root)
                    let state = try await recovered.snapshot()
                    #expect(state.revision == (mode == 1 ? 1 : 0))
                    #expect(state.projects.count == (mode == 1 ? 1 : 0))
                    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("library.sqlite-journal").path))
                    await recovered.close()
                }
            }
        }
    }

    @Test func mutationCrashMatrixAndNoReplay() async throws {
        let points = RecoveryPoint.allCases.map(\.rawValue) + ["privateCommitted", "sessionReopened"]
        for point in points {
            let root = temporaryLibrary()
            defer { try? FileManager.default.removeItem(at: root) }
            try await populated(root)
            #expect(try subprocess(root, action: "mutation", point: point) == 86)
            let owner = try await Library.open(at: root)
            let state = try await owner.snapshot()
            let readyIndex = RecoveryPoint.allCases.firstIndex(of: .ready)!
            let index = RecoveryPoint.allCases.firstIndex { $0.rawValue == point }
            if point == "sessionReopened" || (index != nil && index! >= readyIndex) {
                #expect(state.revision == 2 && state.projects.count == 2)
            } else { #expect(state.revision == 1 && state.projects.count == 1) }
            _ = try await addProject(owner, revision: state.revision)
            await owner.close()
            let next = try await Library.open(at: root)
            #expect(try await next.snapshot().revision == state.revision + 1)
            #expect(try await next.snapshot().projects.count == state.projects.count + 1)
            await next.close()
        }
    }

    @Test func publicationUncertaintyBlocksAndRetainsLease() async throws {
        for point in RecoveryPoint.allCases {
            let root = temporaryLibrary()
            defer { try? FileManager.default.removeItem(at: root) }
            let armed = FaultSwitch()
            let library = try await Library.open(at: root, hooks: RecoveryHooks(recovery: {
                if armed.enabled, $0 == point { throw RecoveryTestError.injected }
            }))
            armed.enable()
            await #expect(throws: LibraryAccessError.publicationIndeterminate) { try await addProject(library, revision: 0) }
            await #expect(throws: LibraryAccessError.unavailable) { try await library.snapshot() }
            await #expect(throws: LibraryAccessError.unavailable) { try await library.setFirstWeekday(4) }
            await #expect(throws: LibraryOpenError.busy) { try await Library.open(at: root) }
            await library.close()
            let next = try await Library.open(at: root)
            #expect(try await next.snapshot().revision <= 1)
            await next.close()
        }
    }

    @Test func invalidAndUnsafeArtifactsPreserveBytes() async throws {
        for name in ["library.sqlite-wal", "library.sqlite-shm", "library.sqlite-other", ".recovery-ready", ".recovery-intent"] {
            let root = temporaryLibrary()
            defer { try? FileManager.default.removeItem(at: root) }
            try await populated(root)
            let main = root.appendingPathComponent("library.sqlite")
            let bytes = try Data(contentsOf: main)
            let bad = root.appendingPathComponent(name)
            let evidence = Data("invalid".utf8)
            try evidence.write(to: bad)
            await expectFailure { try await Library.open(at: root) }
            #expect(try Data(contentsOf: main) == bytes)
            #expect(try Data(contentsOf: bad) == evidence)
        }
        for name in ["library.sqlite", ".library-lock", "settings.plist"] {
            for kind in ["symlink", "hardlink", "directory"] {
                let root = temporaryLibrary()
                defer { try? FileManager.default.removeItem(at: root) }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let source = root.appendingPathComponent("source")
                try Data("evidence".utf8).write(to: source)
                let target = root.appendingPathComponent(name)
                if kind == "symlink" { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source) }
                if kind == "hardlink" { try FileManager.default.linkItem(at: source, to: target) }
                if kind == "directory" { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
                await expectFailure { try await Library.open(at: root) }
                #expect(try Data(contentsOf: source) == Data("evidence".utf8))
            }
        }
        for name in ["library.sqlite-journal", ".recovery-work", ".library-session"] {
            let root = temporaryLibrary()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if name == "library.sqlite-journal" { try Data("orphan".utf8).write(to: root.appendingPathComponent(name)) }
            else { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
            await expectFailure { try await Library.open(at: root) }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("library.sqlite").path))
        }
    }

    @Test func invalidDatabaseAndHotJournalPreserveCanonicalAndSettings() async throws {
        let root = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        try await hotJournal(root, invalidOriginal: true)
        let settings = root.appendingPathComponent("settings.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: ["version": 1, "firstWeekday": 6], format: .xml, options: 0)
        try data.write(to: settings)
        let main = root.appendingPathComponent("library.sqlite")
        let bytes = try Data(contentsOf: main)
        let journal = root.appendingPathComponent("library.sqlite-journal")
        let journalBytes = try Data(contentsOf: journal)
        await expectFailure { try await Library.open(at: root) }
        #expect(try Data(contentsOf: main) == bytes)
        #expect(try Data(contentsOf: journal) == journalBytes)
        #expect(try Data(contentsOf: settings) == data)
    }

    @Test func conflictingReadyAndIntentIdentitiesFailClosed() async throws {
        for name in ["library.sqlite", ".recovery-intent", ".recovery-work/candidate/library.sqlite", ".recovery-work/original/library.sqlite"] {
            let root = temporaryLibrary()
            defer { try? FileManager.default.removeItem(at: root) }
            try await populated(root)
            await expectFailure {
                try await Library.open(at: root, hooks: RecoveryHooks(recovery: {
                    if $0 == .ready { throw RecoveryTestError.injected }
                }))
            }
            let artifact = root.appendingPathComponent(name)
            let evidence = Data("changed identity".utf8)
            try evidence.write(to: artifact)
            await expectFailure { try await Library.open(at: root) }
            #expect(try Data(contentsOf: artifact) == evidence)
        }
        let root = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        try await populated(root)
        await expectFailure {
            try await Library.open(at: root, hooks: RecoveryHooks(recovery: {
                if $0 == .intent { throw RecoveryTestError.injected }
            }))
        }
        let main = root.appendingPathComponent("library.sqlite")
        let evidence = Data("foreign generation".utf8)
        try evidence.write(to: main)
        await expectFailure { try await Library.open(at: root) }
        #expect(try Data(contentsOf: main) == evidence)
    }

    @Test func malformedSettingsAndInvalidInputsNeverReset() async throws {
        let root = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try await Library.open(at: root)
        _ = try await owner.setFirstWeekday(4)
        for day in [-1, 0, 8] { await expectFailure { try await owner.setFirstWeekday(day) } }
        #expect(try await owner.settings().firstWeekday == 4)
        await owner.close()
        let main = try Data(contentsOf: root.appendingPathComponent("library.sqlite"))
        let malformed: [[String: Any]] = [
            ["version": 2, "firstWeekday": 3], ["version": true, "firstWeekday": 3],
            ["version": 1, "firstWeekday": true], ["version": 1, "firstWeekday": 2.0],
            ["version": 1, "firstWeekday": "2"], ["version": 1, "firstWeekday": 8],
            ["version": 1, "firstWeekday": 2, "extra": 0]
        ]
        for value in malformed {
            let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            let settings = root.appendingPathComponent("settings.plist")
            try data.write(to: settings)
            await #expect(throws: LibraryAccessError.self) { try await Library.open(at: root) }
            #expect(try Data(contentsOf: settings) == data)
            #expect(try Data(contentsOf: root.appendingPathComponent("library.sqlite")) == main)
        }
    }

    @Test func settingsFaultsAndCrashesExposeCompleteGenerations() async throws {
        let boundaries: [RecoveryIOPoint] = [.settingsTempCreated, .settingsWritten, .settingsSynced,
                                            .settingsRenamed, .settingsDirectorySynced,
                                            .fileSync, .fullSync, .rename, .directorySync]
        for point in boundaries {
            for crash in [false, true] {
                let root = temporaryLibrary()
                defer { try? FileManager.default.removeItem(at: root) }
                let armed = FaultSwitch()
                let owner = try await Library.open(at: root, hooks: RecoveryHooks(io: {
                    if armed.enabled, $0 == point { throw RecoveryTestError.injected }
                }))
                _ = try await owner.setFirstWeekday(3)
                if crash {
                    await owner.close()
                    #expect(try subprocess(root, action: "settings", point: point.rawValue) == 86)
                } else {
                    armed.enable()
                    await expectFailure { try await owner.setFirstWeekday(7) }
                    if point == .settingsRenamed || point == .settingsDirectorySynced || point == .rename {
                        await #expect(throws: LibraryAccessError.unavailable) { try await owner.snapshot() }
                    } else { #expect(try await owner.settings().firstWeekday == 3) }
                    await owner.close()
                }
                let next = try await Library.open(at: root)
                #expect(try await next.settings().firstWeekday ==
                        (point == .settingsRenamed || point == .settingsDirectorySynced ? 7 : 3))
                #expect(try await next.snapshot().revision == 0)
                await next.close()
            }
        }
    }

    @Test func requiredFilesystemFailuresNeverAcknowledge() async throws {
        for point in [RecoveryIOPoint.copy, .unlink, .rename, .fileSync, .fullSync, .directorySync] {
            let root = temporaryLibrary()
            defer { try? FileManager.default.removeItem(at: root) }
            try await populated(root)
            let before = try Data(contentsOf: root.appendingPathComponent("library.sqlite"))
            await expectFailure {
                try await Library.open(at: root, hooks: RecoveryHooks(io: {
                    if $0 == point { throw RecoveryTestError.injected }
                }))
            }
            #expect(try Data(contentsOf: root.appendingPathComponent("library.sqlite")) == before)
        }
    }

    @Test func fifoCancellationAndCloseDrain() async throws {
        let root = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let latch = PublicationLatch()
        let owner = try await Library.open(at: root, hooks: RecoveryHooks(io: {
            if $0 == .privateCommitted { latch.pauseIfArmed() }
        }))
        latch.arm()
        let mutation = Task { try await addProject(owner, revision: 0) }
        await latch.entered()
        defer { latch.resume() }
        let cancelled = Task { try await owner.setFirstWeekday(7) }
        // Confirm enqueue under actor isolation rather than relying on wall-clock sleeps.
        await owner.waitForQueuedOperations(1)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let setting = Task { try await owner.setFirstWeekday(5) }
        await owner.waitForQueuedOperations(1)
        let closing = Task { await owner.close() }
        await owner.waitForCloseRequest()
        await #expect(throws: LibraryAccessError.unavailable) { try await owner.snapshot() }
        latch.resume()
        #expect(try await mutation.value.snapshot.revision == 1)
        #expect(try await setting.value.firstWeekday == 5)
        await closing.value
        let next = try await Library.open(at: root)
        #expect(try await next.snapshot().revision == 1)
        #expect(try await next.settings().firstWeekday == 5)
        await next.close()
    }
}

private final class PublicationLatch: @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false
    private var didEnter = false
    private var mayLeave = false
    func arm() { condition.withLock { armed = true } }
    func pauseIfArmed() {
        condition.lock()
        defer { condition.unlock() }
        guard armed else { return }
        didEnter = true
        condition.broadcast()
        while !mayLeave { condition.wait() }
    }
    private func waitUntilEntered() {
        condition.lock()
        defer { condition.unlock() }
        while !didEnter { condition.wait() }
    }
    func entered() async {
        await Task.detached { self.waitUntilEntered() }.value
    }
    func resume() { condition.withLock { mayLeave = true; condition.broadcast() } }
}
