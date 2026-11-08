import Foundation
import Observation
import LibraryStore

@MainActor @Observable final class CorrectionForm {
    let entryID: UUID
    let source: TimeEntry?
    var taskID: UUID? { didSet { invalidateConfirmation() } }
    var start: LocalCorrectionTime { didSet { invalidateConfirmation() } }
    var end: LocalCorrectionTime { didSet { invalidateConfirmation() } }
    var timeZone: TimeZone { didSet { start.selectedInstant = nil; end.selectedInstant = nil; invalidateConfirmation() } }
    private(set) var preview: CorrectionPreview?
    private(set) var deletion: DeletionPreview?
    private(set) var confirmationIsStale = false
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = timeZone; return c }
    init(route: CorrectionRoute, snapshot: LibrarySnapshot, now: Date) throws {
        let zone = TimeZone.current
        var c = Calendar(identifier: .gregorian); c.timeZone = zone
        switch route.mode {
        case .add(let task):
            entryID = UUID(); source = nil; taskID = task
            start = Self.fields(now.addingTimeInterval(-3600), calendar: c)
            end = Self.fields(now, calendar: c)
        case .edit(let id):
            guard let entry = snapshot.entries.first(where: { $0.id == id }), let stop = entry.endAt else { throw EditorError.invalid("Only a whole closed entry can be edited.") }
            entryID = entry.id; source = entry; taskID = entry.taskID
            start = Self.fields(Date(timeIntervalSince1970: TimeInterval(entry.startAt)), calendar: c)
            end = Self.fields(Date(timeIntervalSince1970: TimeInterval(stop)), calendar: c)
        }
        timeZone = zone
    }
    static func fields(_ date: Date, calendar: Calendar) -> LocalCorrectionTime {
        LocalCorrectionTime(components: calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date))
    }
    func duration() throws -> Int64 {
        try EntryInterval(startAt: start.resolve(calendar: calendar), endAt: end.resolve(calendar: calendar)).durationSeconds
    }
    func review(in snapshot: LibrarySnapshot) throws {
        guard let taskID else { throw EditorError.invalid("Select a task.") }
        let lo = try start.resolve(calendar: calendar), hi = try end.resolve(calendar: calendar)
        _ = try EntryInterval(startAt: lo, endAt: hi)
        let draft: CorrectionDraft = source == nil
            ? .add(id: entryID, taskID: taskID, startAt: lo, endAt: hi)
            : .edit(id: entryID, taskID: taskID, startAt: lo, endAt: hi)
        preview = try CorrectionPlanner.preview(draft, in: snapshot)
        deletion = nil; confirmationIsStale = false
    }
    func reviewDeletion(in snapshot: LibrarySnapshot) throws {
        guard source != nil else { throw EditorError.invalid("An unsaved entry cannot be deleted.") }
        deletion = try CorrectionPlanner.previewDeletion(entryID: entryID, in: snapshot)
        preview = nil; confirmationIsStale = false
    }
    func invalidateConfirmation() {
        if preview != nil || deletion != nil { confirmationIsStale = true }
    }
    func back() { preview = nil; deletion = nil; confirmationIsStale = false }
}
