import Foundation
import LibraryStore
import UserNotifications

@MainActor final class BudgetNotifications: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let maximumTaskIDs = 128
    private let path: @MainActor (UUID) -> String
    private let reveal: @MainActor (UUID) -> Void
    private let authorizationStatus: @MainActor () async -> UNAuthorizationStatus
    private let requestAuthorization: @MainActor () async throws -> Bool
    private let deliver: @MainActor (UNNotificationRequest) async throws -> Void
    private var baseline: LibrarySnapshot?
    private var seenBatchIDs = Set<UUID>()
    private var seenNoticeIDs = Set<UUID>()
    nonisolated static var foregroundOptions: UNNotificationPresentationOptions { [.banner, .list, .sound] }
    private var authorizationAttempted = false
    private var generation = UUID()
    private var pending: Task<Void, Never>?

    convenience init(
        path: @escaping @MainActor (UUID) -> String,
        reveal: @escaping @MainActor (UUID) -> Void,
        center: UNUserNotificationCenter = .current()
    ) {
        self.init(
            path: path, reveal: reveal,
            authorizationStatus: { await center.notificationSettings().authorizationStatus },
            requestAuthorization: { try await center.requestAuthorization(options: [.alert, .sound]) },
            deliver: { try await center.add($0) })
        center.delegate = self
    }

    // This initializer never obtains a notification center, including in unbundled tests.
    init(
        path: @escaping @MainActor (UUID) -> String,
        reveal: @escaping @MainActor (UUID) -> Void,
        authorizationStatus: @escaping @MainActor () async -> UNAuthorizationStatus,
        requestAuthorization: @escaping @MainActor () async throws -> Bool,
        deliver: @escaping @MainActor (UNNotificationRequest) async throws -> Void
    ) {
        self.path = path
        self.reveal = reveal
        self.authorizationStatus = authorizationStatus
        self.requestAuthorization = requestAuthorization
        self.deliver = deliver
        super.init()
    }

    // Call with nil at the close/reopen boundary; existing batches become baseline, not deliveries.
    func consume(
        snapshot: LibrarySnapshot?, batches: [BudgetWarningBatch],
        acknowledge: (UUID) -> Void = { _ in }
    ) {
        defer { for batch in batches { acknowledge(batch.id) } }
        guard let snapshot else {
            baseline = nil
            generation = UUID()
            seenBatchIDs.formUnion(batches.map(\.id))
            return
        }
        guard let before = baseline, snapshot.revision >= before.revision else {
            baseline = snapshot
            generation = UUID()
            seenBatchIDs.formUnion(batches.map(\.id))
            return
        }
        let previousTasks = Dictionary(uniqueKeysWithValues: before.tasks.map { ($0.id, $0) })
        let enabled =
            snapshot.revision > before.revision
            && snapshot.tasks.contains {
                $0.budgetMinutes != nil && previousTasks[$0.id]?.budgetMinutes == nil
            }
        baseline = snapshot
        let shouldRequest = enabled && !authorizationAttempted

        // Reserve IDs before any await: denial, delivery failure and acknowledgment cannot replay them.
        let requests = batches.compactMap(makeRequest)
        guard shouldRequest || !requests.isEmpty else { return }
        let previous = pending
        let generation = generation
        pending = Task { @MainActor in
            await self.deliver(
                requests,
                previous: previous,
                generation: generation,
                shouldRequest: shouldRequest,
            )
        }
    }

    private func makeRequest(for batch: BudgetWarningBatch) -> UNNotificationRequest? {
        guard seenBatchIDs.insert(batch.id).inserted else { return nil }
        let warnings = batch.warnings.filter { $0.threshold != .none }
        guard !warnings.isEmpty else { return nil }
        let shown = warnings.prefix(Self.maximumTaskIDs)
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.title = "Budget warning"
        content.body = shown.map {
            "\(path($0.taskID)): lifetime budget \($0.threshold.rawValue)% reached"
        }.joined(separator: "\n")
        if shown.count < warnings.count {
            content.body += "\nAnd \(warnings.count - shown.count) more budget warnings."
        }
        content.userInfo = ["taskIDs": shown.map { $0.taskID.uuidString.lowercased() }]
        return UNNotificationRequest(
            identifier: "budget.\(batch.id.uuidString.lowercased())",
            content: content,
            trigger: nil,
        )
    }

    private func deliver(
        _ requests: [UNNotificationRequest],
        previous: Task<Void, Never>?,
        generation: UUID,
        shouldRequest: Bool,
    ) async {
        if let previous { await previous.value }
        guard self.generation == generation else { return }
        let status = await authorizationStatus()
        guard self.generation == generation else { return }
        var allowed = status == .authorized || status == .provisional
        if shouldRequest && !authorizationAttempted {
            authorizationAttempted = true
            if status == .notDetermined {
                allowed = (try? await requestAuthorization()) == true
            }
        }
        guard allowed else { return }
        for request in requests {
            guard self.generation == generation else { return }
            // Delivery is best-effort and never changes the workspace.
            do {
                try await deliver(request)
            } catch {
                continue
            }
        }
    }

    func notify(id: UUID, title: String, body: String, taskIDs: [UUID] = []) {
        guard taskIDs.count <= Self.maximumTaskIDs,
            Set(taskIDs).count == taskIDs.count,
            seenNoticeIDs.insert(id).inserted
        else { return }
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.title = title
        content.body = body
        if !taskIDs.isEmpty {
            content.userInfo = ["taskIDs": taskIDs.map { $0.uuidString.lowercased() }]
        }
        let request = UNNotificationRequest(
            identifier: "notice.\(id.uuidString.lowercased())",
            content: content, trigger: nil)
        let previous = pending
        let generation = generation
        pending = Task { @MainActor in
            if let previous { await previous.value }
            guard self.generation == generation else { return }
            let status = await authorizationStatus()
            guard self.generation == generation,
                status == .authorized || status == .provisional
            else { return }
            // Informational notices do not prompt for permission or mutate the workspace.
            do { try await deliver(request) } catch { return }
        }
    }

    func waitForPendingDelivery() async { await pending?.value }

    nonisolated static func taskIDs(in userInfo: [AnyHashable: Any]) -> [UUID]? {
        guard let values = userInfo["taskIDs"] as? [Any],
            (1...maximumTaskIDs).contains(values.count)
        else { return nil }
        var result: [UUID] = []
        var seen = Set<UUID>()
        for value in values {
            guard let value = value as? String, value.utf8.count == 36, let id = UUID(uuidString: value),
                value == id.uuidString.lowercased(), seen.insert(id).inserted
            else { return nil }
            result.append(id)
        }
        return result
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(Self.foregroundOptions)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleResponse(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo, completion: completionHandler)
    }

    nonisolated func handleResponse(
        actionIdentifier: String, userInfo: [AnyHashable: Any],
        completion: () -> Void
    ) {
        defer { completion() }
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
            let id = Self.taskIDs(in: userInfo)?.first
        else { return }
        Task { @MainActor [weak self] in self?.reveal(id) }
    }
}
