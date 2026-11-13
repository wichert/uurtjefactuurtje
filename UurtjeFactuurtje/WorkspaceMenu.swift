import Foundation
import LibraryStore

@MainActor struct WorkspaceMenu {
    static let autocompleteLimit = 8

    private static func eligibleTasks(_ track: TrackPresentation) -> [TaskRow] {
        track.projects.flatMap { track.allRows(projectID: $0.id) }
            .filter { track.eligible($0.id) }
    }

    static func activeTaskID(_ track: TrackPresentation) -> UUID? {
        guard let snapshot = track.workspace.snapshot,
            let active = snapshot.activeTimer,
            let entry = snapshot.entries.first(where: { $0.id == active.entryID }),
            track.eligible(entry.taskID)
        else {
            return nil
        }
        return entry.taskID
    }

    static func stopTitle(_ track: TrackPresentation) -> String? {
        guard track.ownedStop != nil, let taskID = activeTaskID(track) else { return nil }
        return "Stop \(track.path(taskID))"
    }

    static func startTitle(_ track: TrackPresentation, taskID: UUID) -> String {
        "Start \(track.path(taskID))"
    }

    static func recentTasks(_ track: TrackPresentation, limit: Int = 2) -> [UUID] {
        guard limit > 0 else { return [] }
        let active = activeTaskID(track)
        var seen = Set<UUID>()
        let entries = (track.workspace.snapshot?.entries ?? []).sorted { $0.startAt > $1.startAt }
        var result: [UUID] = []
        for entry in entries {
            guard entry.taskID != active, track.eligible(entry.taskID),
                seen.insert(entry.taskID).inserted
            else { continue }
            result.append(entry.taskID)
            if result.count == limit { break }
        }
        return result
    }

    static func matchingTasks(
        _ track: TrackPresentation, query: String,
        limit: Int = autocompleteLimit
    ) -> [UUID] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        let active = activeTaskID(track)
        return eligibleTasks(track)
            .filter { $0.id != active && $0.path.localizedStandardContains(trimmed) }
            .map(\.id).prefix(limit).map { $0 }
    }
}
