import CoreFoundation
import CryptoKit
import Darwin
import Foundation

// Internal hooks deliberately do not form part of the public opening API.
enum RecoveryPoint: String, CaseIterable, Sendable {
    case intent, copiedOriginal, copiedWorking, validated, ready, journalRetired
    case publicationCopied, published, intentRemoved, readyRemoved
}

enum RecoveryIOPoint: String, CaseIterable, Sendable {
    case copy, unlink, rename, fileSync, fullSync, directorySync
    case settingsTempCreated, settingsWritten, settingsSynced
    case settingsRenamed, settingsDirectorySynced, privateCommitted, sessionReopened
}

struct RecoveryHooks: Sendable {
    var recovery: @Sendable (RecoveryPoint) throws -> Void = { _ in }
    var failureInjector: @Sendable (RecoveryIOPoint) throws -> Void = { _ in }
}

final class LibraryLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    init(directory: URL) throws {
        let path = directory.appendingPathComponent(".library-lock").path
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LibraryOpenError.filesystem("open lock", errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw LibraryOpenError.unsafeState("invalid lock file")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK { throw LibraryOpenError.busy }
            throw LibraryOpenError.filesystem("flock", code)
        }
        self.descriptor = descriptor
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    deinit { release() }
}

// All destructive operations are limited to recognized, type-checked private artifacts.
struct RecoveryFiles: Sendable {
    let hooks: RecoveryHooks

    func status(_ url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw LibraryOpenError.filesystem("lstat \(url.path)", errno)
    }

    func regular(_ url: URL) throws -> Bool {
        guard let info = try status(url) else { return false }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw LibraryOpenError.unsafeState("not a single-link regular file: \(url.path)")
        }
        return true
    }

    func directory(_ url: URL) throws {
        guard let info = try status(url), info.st_mode & S_IFMT == S_IFDIR else {
            throw LibraryOpenError.unsafeState("not a directory: \(url.path)")
        }
    }

    func ensureDirectory(_ url: URL) throws {
        let components = url.pathComponents
        guard url.isFileURL, components.first == "/", !components.contains("..") else {
            throw LibraryOpenError.unsafeState("expected absolute directory")
        }
        var parent = URL(fileURLWithPath: "/", isDirectory: true)
        try directory(parent)
        for component in components.dropFirst() {
            let child = parent.appendingPathComponent(component, isDirectory: true)
            if try status(child) != nil {
                try directory(child)
            } else {
                guard mkdir(child.path, 0o700) == 0 else {
                    throw LibraryOpenError.filesystem("mkdir \(child.path)", errno)
                }
                try syncDirectory(parent)
            }
            parent = child
        }
    }

    func syncDirectory(_ url: URL) throws {
        try directory(url)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LibraryOpenError.filesystem("open directory", errno) }
        do {
            try hooks.failureInjector(.directorySync)
            guard fsync(descriptor) == 0 else { throw LibraryOpenError.filesystem("directory fsync", errno) }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else { throw LibraryOpenError.filesystem("close directory", errno) }
    }

    func flush(_ descriptor: Int32) throws {
        try hooks.failureInjector(.fileSync)
        guard fsync(descriptor) == 0 else { throw LibraryOpenError.filesystem("file fsync", errno) }
        try hooks.failureInjector(.fullSync)
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else {
            throw LibraryOpenError.filesystem("F_FULLFSYNC", errno)
        }
    }

    func read(_ url: URL) throws -> Data {
        guard try regular(url) else { throw LibraryOpenError.unsafeState("missing file: \(url.path)") }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LibraryOpenError.filesystem("open read", errno) }
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 65_536)
        do {
            while true {
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw LibraryOpenError.filesystem("read", errno) }
                if count == 0 { break }
                result.append(contentsOf: bytes.prefix(count))
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else { throw LibraryOpenError.filesystem("close read", errno) }
        return result
    }

    func write(_ data: Data, to url: URL, settings: Bool = false) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LibraryOpenError.filesystem("exclusive create", errno) }
        do {
            if settings { try hooks.failureInjector(.settingsTempCreated) }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(
                        descriptor, buffer.baseAddress!.advanced(by: offset),
                        buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw LibraryOpenError.filesystem("write", errno) }
                    offset += count
                }
            }
            if settings { try hooks.failureInjector(.settingsWritten) }
            try flush(descriptor)
            if settings { try hooks.failureInjector(.settingsSynced) }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else { throw LibraryOpenError.filesystem("close write", errno) }
        try syncDirectory(url.deletingLastPathComponent())
    }

    func copy(_ source: URL, _ destination: URL) throws {
        try hooks.failureInjector(.copy)
        // Streaming avoids mapping files that SQLite is about to replace or recover.
        guard try regular(source) else { throw LibraryOpenError.unsafeState("missing copy source") }
        let input = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw LibraryOpenError.filesystem("open copy source", errno) }
        let output = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else {
            let code = errno
            Darwin.close(input)
            throw LibraryOpenError.filesystem("create copy", code)
        }
        do {
            var bytes = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = Darwin.read(input, &bytes, bytes.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw LibraryOpenError.filesystem("read copy", errno) }
                if count == 0 { break }
                try bytes.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < count {
                        let written = Darwin.write(output, buffer.baseAddress!.advanced(by: offset), count - offset)
                        if written < 0, errno == EINTR { continue }
                        guard written > 0 else { throw LibraryOpenError.filesystem("write copy", errno) }
                        offset += written
                    }
                }
            }
            try flush(output)
        } catch {
            Darwin.close(input)
            Darwin.close(output)
            throw error
        }
        let inputResult = Darwin.close(input)
        let inputError = errno
        let outputResult = Darwin.close(output)
        let outputError = errno
        guard inputResult == 0 else { throw LibraryOpenError.filesystem("close source", inputError) }
        guard outputResult == 0 else { throw LibraryOpenError.filesystem("close copy", outputError) }
        try syncDirectory(destination.deletingLastPathComponent())
    }

    func digest(_ url: URL) throws -> String {
        guard try regular(url) else { throw LibraryOpenError.unsafeState("missing digest source") }
        let handle = try FileHandle(forReadingFrom: url)
        var hash = SHA256()
        do {
            while let bytes = try handle.read(upToCount: 65_536), !bytes.isEmpty { hash.update(data: bytes) }
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func rename(_ source: URL, _ destination: URL) throws {
        try hooks.failureInjector(.rename)
        guard try regular(source) else { throw LibraryOpenError.unsafeState("missing rename source") }
        _ = try regular(destination)
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw LibraryOpenError.filesystem("rename", errno)
        }
        try syncDirectory(destination.deletingLastPathComponent())
    }

    func remove(_ url: URL) throws {
        guard let info = try status(url) else { return }
        if info.st_mode & S_IFMT == S_IFDIR {
            try directory(url)
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                try remove(url.appendingPathComponent(name))
            }
            try hooks.failureInjector(.unlink)
            guard rmdir(url.path) == 0 else { throw LibraryOpenError.filesystem("rmdir", errno) }
        } else {
            _ = try regular(url)
            try hooks.failureInjector(.unlink)
            guard unlink(url.path) == 0 else { throw LibraryOpenError.filesystem("unlink", errno) }
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    func inspectTree(_ url: URL) throws {
        guard let info = try status(url) else { return }
        if info.st_mode & S_IFMT == S_IFDIR {
            try directory(url)
            let allowed: Set<String> =
                url.lastPathComponent == ".recovery-work"
                ? ["original", "candidate", "check"] : ["library.sqlite", "library.sqlite-journal", ".flushed"]
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                guard allowed.contains(name) else {
                    throw LibraryOpenError.unsafeState("unexpected workspace artifact: \(name)")
                }
                let child = url.appendingPathComponent(name)
                if url.lastPathComponent == ".recovery-work" { try directory(child) } else { _ = try regular(child) }
                try inspectTree(child)
            }
        } else {
            _ = try regular(url)
        }
    }
}

struct Recovery: Sendable {
    let root: URL
    let hooks: RecoveryHooks
    var files: RecoveryFiles { RecoveryFiles(hooks: hooks) }
    func path(_ name: String) -> URL { root.appendingPathComponent(name) }
    private var main: URL { path("library.sqlite") }
    private var journal: URL { path("library.sqlite-journal") }
    private var work: URL { path(".recovery-work") }
    private var candidate: URL { path(".recovery-work/candidate/library.sqlite") }

    private struct Intent: Codable, Equatable {
        let version: Int
        let mode: String
        let original: String?
        let journal: String?
    }
    private struct Ready: Codable {
        let version: Int
        let intent: Intent
        let candidate: String
    }

    private func validHash(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func validate(_ intent: Intent) throws {
        guard intent.version == 1,
            (intent.mode == "create" && intent.original == nil && intent.journal == nil)
                || (intent.mode == "existing" && validHash(intent.original) && intent.journal == nil)
                || (intent.mode == "existing+journal" && validHash(intent.original) && validHash(intent.journal))
        else {
            throw LibraryOpenError.unsafeState("malformed recovery intent")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
        let url = path(name)
        guard try files.regular(url) else { return nil }
        let data = try files.read(url)
        guard data.count <= 4096 else { throw LibraryOpenError.unsafeState("oversized recovery marker") }
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw LibraryOpenError.unsafeState("malformed recovery marker: \(name)")
        }
    }

    private func marker<T: Encodable>(_ value: T, _ name: String) throws {
        let temp = path(name + ".tmp")
        try files.remove(temp)
        try files.write(JSONEncoder().encode(value), to: temp)
        try files.rename(temp, path(name))
    }

    private func currentIntent() throws -> Intent {
        let exists = try files.regular(main)
        let hasJournal = try files.regular(journal)
        guard exists || !hasJournal else { throw LibraryOpenError.unsafeState("orphan journal") }
        return Intent(
            version: 1, mode: exists ? (hasJournal ? "existing+journal" : "existing") : "create",
            original: exists ? try files.digest(main) : nil,
            journal: hasJournal ? try files.digest(journal) : nil)
    }

    func inspect() throws {
        try files.directory(root)
        let allowed: Set<String> = [
            ".library-lock", "library.sqlite", "library.sqlite-journal", "settings.plist",
            ".settings.tmp", ".recovery-work", ".library-session", ".recovery-intent", ".recovery-ready",
            ".recovery-intent.tmp", ".recovery-ready.tmp", ".recovery-publish"
        ]
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) {
            guard allowed.contains(name) else {
                throw LibraryOpenError.unsafeState("unsupported library artifact: \(name)")
            }
            if name == ".recovery-work" || name == ".library-session" {
                try files.directory(path(name))
                try files.inspectTree(path(name))
            } else {
                _ = try files.regular(path(name))
            }
        }
        if !(try files.regular(main)), try files.status(work) != nil,
            !(try files.regular(path(".recovery-intent"))), !(try files.regular(path(".recovery-ready"))) {
            throw LibraryOpenError.unsafeState("orphan recovery workspace")
        }
        if try files.status(path(".library-session")) != nil {
            guard try files.regular(main), try files.regular(path(".library-session/library.sqlite")) else {
                throw LibraryOpenError.unsafeState("orphan session workspace")
            }
        }
    }

    private func validatePrivate(_ url: URL) async throws {
        let storage = try Storage(privateDatabaseAt: url)
        do { _ = try await storage.snapshot() } catch {
            await storage.close()
            throw error
        }
        await storage.close()
        guard !(try files.regular(URL(fileURLWithPath: url.path + "-journal"))) else {
            throw LibraryOpenError.unsafeState("validated candidate retains journal")
        }
        // Re-copying flushes the post-rollback bytes, never the canonical pair.
        let flushCopy = url.deletingLastPathComponent().appendingPathComponent(".flushed")
        try files.remove(flushCopy)
        try files.copy(url, flushCopy)
        try files.rename(flushCopy, url)
    }

    func recover() async throws {
        try inspect()
        if let ready = try decode(Ready.self, ".recovery-ready") {
            try await install(ready)
            return
        }
        let original = try currentIntent()
        if let intent = try decode(Intent.self, ".recovery-intent") {
            try validate(intent)
            guard intent == original else { throw LibraryOpenError.unsafeState("intent/canonical identity mismatch") }
        } else {
            try marker(original, ".recovery-intent")
        }
        try hooks.recovery(.intent)
        try await prepare(original, replacement: nil)
    }

    func publish(from privateDatabase: URL) async throws {
        guard !(try files.regular(path(".recovery-ready"))),
            !(try files.regular(path(".recovery-intent")))
        else {
            throw LibraryOpenError.unsafeState("publication already in progress")
        }
        let original = try currentIntent()
        guard original.mode == "existing" else {
            throw LibraryOpenError.unsafeState("publication lost canonical generation")
        }
        try marker(original, ".recovery-intent")
        try hooks.recovery(.intent)
        try await prepare(original, replacement: privateDatabase)
    }

    private func prepare(_ intent: Intent, replacement: URL?) async throws {
        try files.remove(work)
        try files.remove(path(".recovery-ready.tmp"))
        try files.remove(path(".recovery-publish"))
        try files.ensureDirectory(path(".recovery-work/original"))
        try files.ensureDirectory(path(".recovery-work/candidate"))
        if intent.original != nil { try files.copy(main, path(".recovery-work/original/library.sqlite")) }
        if intent.journal != nil { try files.copy(journal, path(".recovery-work/original/library.sqlite-journal")) }
        try hooks.recovery(.copiedOriginal)
        if let replacement {
            try files.copy(replacement, candidate)
        } else if intent.original != nil {
            try files.copy(path(".recovery-work/original/library.sqlite"), candidate)
            if intent.journal != nil {
                try files.copy(
                    path(".recovery-work/original/library.sqlite-journal"),
                    path(".recovery-work/candidate/library.sqlite-journal"))
            }
        } else {
            try Storage.createPrivateDatabase(at: candidate)
        }
        try hooks.recovery(.copiedWorking)
        try await validatePrivate(candidate)
        try hooks.recovery(.validated)
        guard try currentIntent() == intent else {
            throw LibraryOpenError.unsafeState("canonical changed during preparation")
        }
        let ready = Ready(version: 1, intent: intent, candidate: try files.digest(candidate))
        try marker(ready, ".recovery-ready")
        try hooks.recovery(.ready)
        try await install(ready)
    }

    private func install(_ ready: Ready) async throws {
        try validate(ready.intent)
        guard ready.version == 1, validHash(ready.candidate) else {
            throw LibraryOpenError.unsafeState("malformed ready record")
        }
        if let intent = try decode(Intent.self, ".recovery-intent"), intent != ready.intent {
            throw LibraryOpenError.unsafeState("conflicting intent/ready")
        }
        try files.directory(work)
        try files.directory(path(".recovery-work/original"))
        try files.directory(path(".recovery-work/candidate"))
        guard try files.digest(candidate) == ready.candidate,
            !(try files.regular(path(".recovery-work/candidate/library.sqlite-journal")))
        else {
            throw LibraryOpenError.unsafeState("candidate identity mismatch")
        }
        if let hash = ready.intent.original {
            guard try files.digest(path(".recovery-work/original/library.sqlite")) == hash else {
                throw LibraryOpenError.unsafeState("original main identity mismatch")
            }
        } else if try files.status(path(".recovery-work/original/library.sqlite")) != nil {
            throw LibraryOpenError.unsafeState("unexpected original main")
        }
        if let hash = ready.intent.journal {
            guard try files.digest(path(".recovery-work/original/library.sqlite-journal")) == hash else {
                throw LibraryOpenError.unsafeState("original journal identity mismatch")
            }
        } else if try files.status(path(".recovery-work/original/library.sqlite-journal")) != nil {
            throw LibraryOpenError.unsafeState("unexpected original journal")
        }
        let currentMain = try files.regular(main) ? files.digest(main) : nil
        let currentJournal = try files.regular(journal) ? files.digest(journal) : nil
        let isOriginal = currentMain == ready.intent.original
        let isCandidate = currentMain == ready.candidate
        guard
            (isOriginal && (currentJournal == nil || currentJournal == ready.intent.journal))
                || (isCandidate && currentJournal == nil)
        else {
            throw LibraryOpenError.unsafeState("conflicting canonical generation")
        }
        // Ready's candidate stays immutable; SQLite revalidates another disposable copy.
        let check = path(".recovery-work/check")
        try files.remove(check)
        try files.ensureDirectory(check)
        let checkDB = check.appendingPathComponent("library.sqlite")
        try files.copy(candidate, checkDB)
        try await validatePrivate(checkDB)
        guard try files.digest(checkDB) == ready.candidate else {
            throw LibraryOpenError.unsafeState("candidate changed during validation")
        }
        if currentJournal != nil { try files.remove(journal) }
        try hooks.recovery(.journalRetired)
        if !isCandidate {
            try files.remove(path(".recovery-publish"))
            try files.copy(candidate, path(".recovery-publish"))
            try hooks.recovery(.publicationCopied)
            try files.rename(path(".recovery-publish"), main)
        } else {
            try hooks.recovery(.publicationCopied)
        }
        try hooks.recovery(.published)
        guard try files.digest(main) == ready.candidate, !(try files.regular(journal)) else {
            throw LibraryOpenError.unsafeState("published generation mismatch")
        }
        try files.remove(path(".recovery-intent"))
        try hooks.recovery(.intentRemoved)
        try files.remove(path(".recovery-ready"))
        try hooks.recovery(.readyRemoved)
        // Old workspace bytes can only be discarded, never replayed without ready.
    }

    func newSession() throws -> URL {
        guard !(try files.regular(path(".recovery-ready"))),
            !(try files.regular(path(".recovery-intent")))
        else {
            throw LibraryOpenError.unsafeState("session before publication complete")
        }
        let session = path(".library-session")
        try files.remove(session)
        try files.ensureDirectory(session)
        let database = session.appendingPathComponent("library.sqlite")
        try files.copy(main, database)
        return database
    }

    func settings() throws -> LibrarySettings {
        let url = path("settings.plist")
        guard try files.regular(url) else { return LibrarySettings(firstWeekday: 2) }
        let data = try files.read(url)
        do {
            let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let dictionary = object as? [String: Any], Set(dictionary.keys) == ["version", "firstWeekday"],
                let version = dictionary["version"] as? NSNumber,
                let weekday = dictionary["firstWeekday"] as? NSNumber,
                CFGetTypeID(version) != CFBooleanGetTypeID(), CFGetTypeID(weekday) != CFBooleanGetTypeID(),
                CFNumberIsFloatType(unsafeBitCast(version, to: CFNumber.self)) == false,
                CFNumberIsFloatType(unsafeBitCast(weekday, to: CFNumber.self)) == false,
                version.intValue == 1, (1...7).contains(weekday.intValue),
                version == NSNumber(value: 1), weekday == NSNumber(value: weekday.intValue)
            else {
                throw LibraryAccessError.invalidSettings("expected integer version 1 and weekday 1...7")
            }
            return LibrarySettings(firstWeekday: weekday.intValue)
        } catch let error as LibraryAccessError { throw error } catch {
            throw LibraryAccessError.invalidSettings("malformed settings.plist")
        }
    }

    func saveSettings(_ day: Int) throws -> LibrarySettings {
        guard (1...7).contains(day) else { throw LibraryAccessError.invalidSettings("weekday must be 1...7") }
        _ = try settings()
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["version": 1, "firstWeekday": day],
            format: .xml, options: 0)
        let temp = path(".settings.tmp")
        try files.remove(temp)
        try files.write(data, to: temp, settings: true)
        // Once rename is attempted, even a directory-barrier failure is uncertain.
        do {
            try files.rename(temp, path("settings.plist"))
            try hooks.failureInjector(.settingsRenamed)
            try files.syncDirectory(root)
            try hooks.failureInjector(.settingsDirectorySynced)
        } catch { throw LibraryAccessError.publicationIndeterminate }
        return LibrarySettings(firstWeekday: day)
    }
}
