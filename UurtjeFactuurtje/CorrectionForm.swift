import Foundation
import Observation
import LibraryStore

@MainActor @Observable final class CorrectionForm {
    let entryID: UUID
    let source: TimeEntry?
    var taskID: UUID? { didSet { invalidateConfirmation() } }
    var start: LocalCorrectionTime { didSet { invalidateConfirmation() } }
    var end: LocalCorrectionTime { didSet { invalidateConfirmation() } }
    let timeZone: TimeZone
    private(set) var preview: CorrectionPreview?
    private(set) var deletion: DeletionPreview?
    private(set) var confirmationIsStale = false
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
    init(route: CorrectionRoute, snapshot: LibrarySnapshot, now: Date,
         timeZone: TimeZone = .current) throws {
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        switch route.mode {
        case .add(let task):
            entryID = UUID(); source = nil; taskID = task
            start = Self.fields(now.addingTimeInterval(-3600), calendar: calendar)
            end = Self.fields(now, calendar: calendar)
        case .edit(let id):
            guard let entry = snapshot.entries.first(where: { $0.id == id }),
                  let stop = entry.endAt else {
                throw EditorError.invalid("Only a whole closed entry can be edited.")
            }
            entryID = entry.id; source = entry; taskID = entry.taskID
            start = Self.fields(Date(timeIntervalSince1970: TimeInterval(entry.startAt)),
                                calendar: calendar, preservingPrecision: true)
            end = Self.fields(Date(timeIntervalSince1970: TimeInterval(stop)),
                              calendar: calendar, preservingPrecision: true)
        }
    }

    static func fields(_ date: Date, calendar: Calendar,
                       preservingPrecision: Bool = false) -> LocalCorrectionTime {
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        if !preservingPrecision { components.second = 0 }
        return LocalCorrectionTime(components: components,
            selectedInstant: preservingPrecision ? Int64(date.timeIntervalSince1970) : nil)
    }

    static var pickerCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func pickerDate(for value: LocalCorrectionTime) -> Date {
        var components = value.components
        components.calendar = nil
        components.timeZone = nil
        components.second = 0
        components.nanosecond = nil
        // Form values originate in valid saved dates or the native Gregorian carrier.
        return pickerCalendar.date(from: components)!
    }

    static func choosingOccurrence(_ instant: Int64?, for value: LocalCorrectionTime,
                                   calendar: Calendar) -> LocalCorrectionTime {
        guard instant != value.selectedInstant else { return value }
        let earlierChoice: Bool
        switch CorrectionClock.resolve(value.components, calendar: calendar) {
        case .ambiguous(let earlier, let later, _, _):
            guard instant == nil || instant == earlier || instant == later else { return value }
            earlierChoice = instant == earlier
        default: return value
        }
        var changed = value
        changed.components.second = 0
        changed.selectedInstant = nil
        if instant != nil,
           case .ambiguous(let earlier, let later, _, _) = CorrectionClock.resolve(
               changed.components, calendar: calendar) {
            changed.selectedInstant = earlierChoice ? earlier : later
        }
        return changed
    }

    static func applyingPickerDate(_ date: Date, to value: LocalCorrectionTime) -> LocalCorrectionTime {
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]
        var changed = pickerCalendar.dateComponents(fields, from: date)
        let original = DateComponents(year: value.components.year, month: value.components.month,
            day: value.components.day, hour: value.components.hour, minute: value.components.minute)
        guard changed != original else { return value }
        changed.second = 0
        return LocalCorrectionTime(components: changed)
    }
    func duration() throws -> Int64 {
        try EntryInterval(startAt: start.resolve(calendar: calendar),
                          endAt: end.resolve(calendar: calendar)).durationSeconds
    }
    func review(in snapshot: LibrarySnapshot) throws {
        guard let taskID else { throw EditorError.invalid("Select a task.") }
        let startAt = try start.resolve(calendar: calendar)
        let endAt = try end.resolve(calendar: calendar)
        _ = try EntryInterval(startAt: startAt, endAt: endAt)
        let draft: CorrectionDraft = source == nil
            ? .add(id: entryID, taskID: taskID, startAt: startAt, endAt: endAt)
            : .edit(id: entryID, taskID: taskID, startAt: startAt, endAt: endAt)
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
