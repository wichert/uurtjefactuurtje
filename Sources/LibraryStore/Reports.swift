import Foundation

public enum ReportPeriod: Equatable, Sendable {
    case allTime, thisWeek, thisMonth
    case custom(first: DateComponents, last: DateComponents)
    case day(containing: Int64)
}

public enum ReportError: Error, Equatable, Sendable {
    case unavailableProject, invalidDate, reversedDates, intervalOverflow
    case invalidActiveEntry, invalidHierarchy, unknownCurrency, moneyOverflow
}

public struct ReportBounds: Equatable, Sendable {
    public let start: Int64
    public let end: Int64
    public init(start: Int64, end: Int64) throws {
        guard end > start, !end.subtractingReportingOverflow(start).overflow else {
            throw ReportError.intervalOverflow
        }
        self.start = start
        self.end = end
    }
}

public enum ReportCalendar {
    static func date(_ second: Int64) throws -> Date {
        guard Int64(exactly: Double(second)) == second else { throw ReportError.invalidDate }
        return Date(timeIntervalSince1970: Double(second))
    }

    static func bounds(_ interval: DateInterval) throws -> ReportBounds {
        guard let start = Int64(exactly: interval.start.timeIntervalSince1970),
              let end = Int64(exactly: interval.end.timeIntervalSince1970) else {
            throw ReportError.intervalOverflow
        }
        return try ReportBounds(start: start, end: end)
    }

    static func civilDate(_ components: DateComponents, calendar: Calendar) throws -> Date {
        guard components.year != nil, components.month != nil, components.day != nil else {
            throw ReportError.invalidDate
        }
        var civil = DateComponents()
        civil.era = components.era
        civil.year = components.year
        civil.month = components.month
        civil.day = components.day
        civil.isLeapMonth = components.isLeapMonth
        // Noon avoids a nonexistent midnight; dateInterval supplies the actual day start.
        civil.hour = 12
        guard let date = calendar.date(from: civil) else { throw ReportError.invalidDate }
        let actual = calendar.dateComponents([.era, .year, .month, .day, .isLeapMonth], from: date)
        guard actual.year == civil.year, actual.month == civil.month, actual.day == civil.day,
              civil.era == nil || actual.era == civil.era,
              civil.isLeapMonth == nil || actual.isLeapMonth == civil.isLeapMonth else {
            throw ReportError.invalidDate
        }
        return date
    }

    static func day(_ date: Date, calendar: Calendar) throws -> ReportBounds {
        guard let interval = calendar.dateInterval(of: .day, for: date) else { throw ReportError.invalidDate }
        return try bounds(interval)
    }

    static func nominalWeekStart(containing: Int64, calendar: Calendar, firstWeekday: Int) throws -> Date {
        guard (1...7).contains(firstWeekday) else { throw ReportError.invalidDate }
        let anchor = try date(containing)
        let civil = calendar.dateComponents([.era, .year, .month, .day, .isLeapMonth], from: anchor)
        var nominal = calendar
        nominal.timeZone = TimeZone(secondsFromGMT: 0)!
        let offset = (calendar.component(.weekday, from: anchor) - firstWeekday + 7) % 7
        guard let start = nominal.date(byAdding: .day, value: -offset, to: try civilDate(civil, calendar: nominal)) else {
            throw ReportError.invalidDate
        }
        return start
    }

    static func boundary(_ nominalDate: Date, calendar: Calendar) throws -> Int64 {
        var nominal = calendar
        nominal.timeZone = TimeZone(secondsFromGMT: 0)!
        // A skipped boundary starts at the next existing civil day, never invented elapsed time.
        for offset in 0..<7 {
            guard let candidate = nominal.date(byAdding: .day, value: offset, to: nominalDate) else {
                throw ReportError.invalidDate
            }
            let civil = nominal.dateComponents([.era, .year, .month, .day, .isLeapMonth], from: candidate)
            if let actual = try? civilDate(civil, calendar: calendar) {
                return try day(actual, calendar: calendar).start
            }
        }
        throw ReportError.invalidDate
    }

    public static func bounds(for period: ReportPeriod, now: Int64, calendar: Calendar,
                              firstWeekday: Int = 2) throws -> ReportBounds? {
        guard (1...7).contains(firstWeekday) else { throw ReportError.invalidDate }
        var calendar = calendar
        calendar.firstWeekday = firstWeekday
        switch period {
        case .allTime: return nil
        case let .custom(first, last):
            let firstDate = try civilDate(first, calendar: calendar)
            let lastDate = try civilDate(last, calendar: calendar)
            guard firstDate <= lastDate else { throw ReportError.reversedDates }
            return try ReportBounds(start: day(firstDate, calendar: calendar).start,
                                    end: day(lastDate, calendar: calendar).end)
        case let .day(containing): return try day(date(containing), calendar: calendar)
        case .thisWeek:
            let start = try nominalWeekStart(containing: now, calendar: calendar, firstWeekday: firstWeekday)
            var nominal = calendar
            nominal.timeZone = TimeZone(secondsFromGMT: 0)!
            guard let end = nominal.date(byAdding: .day, value: 7, to: start) else { throw ReportError.invalidDate }
            return try ReportBounds(start: boundary(start, calendar: calendar), end: boundary(end, calendar: calendar))
        case .thisMonth:
            guard let interval = calendar.dateInterval(of: .month, for: try date(now)) else {
                throw ReportError.invalidDate
            }
            return try bounds(interval)
        }
    }
}

public struct ReportValue: Equatable, Sendable {
    public let closedSeconds: Int64
    public let provisionalSeconds: Int64
    public let totalSeconds: Int64
    public static let zero = ReportValue(closedSeconds: 0, provisionalSeconds: 0, totalSeconds: 0)

    fileprivate func adding(_ other: ReportValue) throws -> ReportValue {
        func sum(_ a: Int64, _ b: Int64) throws -> Int64 {
            let (value, overflow) = a.addingReportingOverflow(b)
            guard !overflow else { throw ReportError.intervalOverflow }
            return value
        }
        return try ReportValue(closedSeconds: sum(closedSeconds, other.closedSeconds),
                               provisionalSeconds: sum(provisionalSeconds, other.provisionalSeconds),
                               totalSeconds: sum(totalSeconds, other.totalSeconds))
    }
}

public struct ReportEntryRow: Identifiable, Equatable, Sendable {
    public var id: UUID { entry.id }
    public let entry: TimeEntry
    public let included: EntryInterval?
    public let isProvisional: Bool
    public var seconds: Int64 { included?.durationSeconds ?? 0 }
}

public struct CurrencyAmount: Equatable, Sendable {
    public let currencyCode: String
    public let minorUnits: String
    public let fractionDigits: Int
}

public struct ProjectReport: Equatable, Sendable {
    public let project: Project
    public let bounds: ReportBounds?
    public let timeZoneIdentifier: String
    public let tasks: [TaskRecord]
    public let total: ReportValue
    public let taskTotals: [UUID: ReportValue]
    public let lifetimeUsage: [UUID: Decimal]
    public let displayBands: [UUID: WarningThreshold]
    public let entriesByLeaf: [UUID: [ReportEntryRow]]
    public let hasOpenEntry: Bool
}

public struct WeeklyReportDay: Equatable, Sendable {
    public let date: DateComponents
    public let bounds: ReportBounds?
    public let projects: [UUID: ReportValue]
    public let openProjectIDs: Set<UUID>
    public let total: ReportValue
}

public struct WeeklyReport: Equatable, Sendable {
    public let bounds: ReportBounds
    public let timeZoneIdentifier: String
    public let projects: [Project]
    public let days: [WeeklyReportDay]
    public let projectTotals: [UUID: ReportValue]
    public let total: ReportValue
    public let hasOpenEntry: Bool
}

public enum ReportProjection {
    private struct Prepared {
        let tasks: [UUID: TaskRecord]
        let bottomUp: [UUID]
        let rows: [ReportEntryRow]

        init(_ snapshot: LibrarySnapshot, liveEnd: Int64?) throws {
            let errors = SnapshotValidator.violations(in: snapshot, now: nil, includingBudgets: false)
            if errors.contains(where: { $0.code == .timer }) { throw ReportError.invalidActiveEntry }
            if errors.contains(where: { $0.code == .interval }) { throw ReportError.intervalOverflow }
            guard errors.isEmpty else { throw ReportError.invalidHierarchy }
            tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
            var remaining: [UUID: Int] = [:]
            for task in snapshot.tasks {
                if let parent = task.parentTaskID { remaining[parent, default: 0] += 1 }
            }
            var order = snapshot.tasks.filter { remaining[$0.id] == nil }.map(\.id)
            var index = 0
            while index < order.count {
                if let parent = tasks[order[index]]?.parentTaskID {
                    remaining[parent, default: 0] -= 1
                    if remaining[parent] == 0 { order.append(parent) }
                }
                index += 1
            }
            guard order.count == snapshot.tasks.count else { throw ReportError.invalidHierarchy }
            bottomUp = order
            rows = try snapshot.entries.map { entry in
                let provisional = entry.endAt == nil
                let end: Int64
                if let closed = entry.endAt { end = closed }
                else {
                    guard let active = snapshot.activeTimer, active.entryID == entry.id,
                          liveEnd == nil || liveEnd! >= active.checkpointAt else {
                        throw ReportError.invalidActiveEntry
                    }
                    end = liveEnd ?? active.checkpointAt
                }
                let interval: EntryInterval?
                if provisional && end == entry.startAt { interval = nil }
                else {
                    do { interval = try EntryInterval(startAt: entry.startAt, endAt: end) }
                    catch { throw ReportError.intervalOverflow }
                }
                return ReportEntryRow(entry: entry, included: interval, isProvisional: provisional)
            }
        }

        func clipped(_ row: ReportEntryRow, to bounds: ReportBounds?) throws -> ReportEntryRow? {
            guard let bounds else { return row }
            if let interval = row.included {
                let range = try EntryInterval(startAt: bounds.start, endAt: bounds.end)
                guard let included = interval.intersection(range) else { return nil }
                return ReportEntryRow(entry: row.entry, included: included, isProvisional: row.isProvisional)
            }
            return bounds.start <= row.entry.startAt && row.entry.startAt < bounds.end ? row : nil
        }
    }

    private static func value(_ row: ReportEntryRow) -> ReportValue {
        ReportValue(closedSeconds: row.isProvisional ? 0 : row.seconds,
                    provisionalSeconds: row.isProvisional ? row.seconds : 0, totalSeconds: row.seconds)
    }

    private static func ordered(_ left: (String, UUID), _ right: (String, UUID)) -> Bool {
        let a = NameKey.make(left.0), b = NameKey.make(right.0)
        return a == b ? left.1.uuidString < right.1.uuidString : a < b
    }

    public static func project(_ projectID: UUID, in snapshot: LibrarySnapshot,
                               bounds: ReportBounds?, calendar: Calendar,
                               liveEnd: Int64? = nil) throws -> ProjectReport {
        guard let project = snapshot.projects.first(where: { $0.id == projectID }) else {
            throw ReportError.unavailableProject
        }
        let prepared = try Prepared(snapshot, liveEnd: liveEnd)
        let tasks = snapshot.tasks.filter { $0.projectID == projectID }.sorted {
            ordered(($0.name, $0.id), ($1.name, $1.id))
        }
        var totals = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, ReportValue.zero) })
        let parents = Set(tasks.compactMap(\.parentTaskID))
        var rows = Dictionary(uniqueKeysWithValues: tasks.filter { !parents.contains($0.id) }
            .map { ($0.id, [ReportEntryRow]()) })
        var total = ReportValue.zero
        var hasOpen = false
        for original in prepared.rows where prepared.tasks[original.entry.taskID]?.projectID == projectID {
            guard let row = try prepared.clipped(original, to: bounds) else { continue }
            total = try total.adding(value(row))
            totals[row.entry.taskID] = try totals[row.entry.taskID, default: .zero].adding(value(row))
            rows[row.entry.taskID, default: []].append(row)
            hasOpen = hasOpen || row.isProvisional
        }
        for id in prepared.bottomUp where totals[id] != nil {
            if let parent = prepared.tasks[id]?.parentTaskID {
                totals[parent] = try totals[parent, default: .zero].adding(totals[id]!)
            }
        }
        for id in rows.keys {
            rows[id]!.sort {
                let a = $0.included?.startAt ?? $0.entry.startAt
                let b = $1.included?.startAt ?? $1.entry.startAt
                return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
            }
        }
        let usage = try BudgetRules.usage(in: snapshot, liveEnd: liveEnd).filter { totals[$0.key] != nil }
        let bands = Dictionary(uniqueKeysWithValues: tasks.map {
            ($0.id, BudgetRules.band(used: usage[$0.id, default: 0], budget: $0.budgetSeconds))
        })
        return ProjectReport(project: project, bounds: bounds, timeZoneIdentifier: calendar.timeZone.identifier,
                             tasks: tasks, total: total, taskTotals: totals, lifetimeUsage: usage,
                             displayBands: bands, entriesByLeaf: rows, hasOpenEntry: hasOpen)
    }

    public static func week(in snapshot: LibrarySnapshot, containing: Int64, calendar: Calendar,
                            firstWeekday: Int = 2, includeArchived: Bool = false,
                            liveEnd: Int64? = nil) throws -> WeeklyReport {
        let bounds = try ReportCalendar.bounds(for: .thisWeek, now: containing, calendar: calendar,
                                              firstWeekday: firstWeekday)!
        let prepared = try Prepared(snapshot, liveEnd: liveEnd)
        let projects = snapshot.projects.filter { includeArchived || !$0.isArchived }.sorted {
            ordered(($0.name, $0.id), ($1.name, $1.id))
        }
        let zero = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, ReportValue.zero) })
        var totals = zero
        var total = ReportValue.zero
        var days: [WeeklyReportDay] = []
        var nominalCalendar = calendar
        nominalCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let nominalStart = try ReportCalendar.nominalWeekStart(containing: containing, calendar: calendar,
                                                               firstWeekday: firstWeekday)
        for offset in 0..<7 {
            guard let nominal = nominalCalendar.date(byAdding: .day, value: offset, to: nominalStart) else {
                throw ReportError.invalidDate
            }
            let civil = nominalCalendar.dateComponents([.era, .year, .month, .day, .isLeapMonth], from: nominal)
            let dayBounds: ReportBounds?
            do { dayBounds = try ReportCalendar.day(ReportCalendar.civilDate(civil, calendar: calendar), calendar: calendar) }
            catch ReportError.invalidDate { dayBounds = nil }
            var cells = zero
            var open = Set<UUID>()
            var dayTotal = ReportValue.zero
            if let dayBounds {
                for original in prepared.rows {
                    guard let project = prepared.tasks[original.entry.taskID]?.projectID, cells[project] != nil,
                          let row = try prepared.clipped(original, to: dayBounds) else { continue }
                    let contribution = value(row)
                    cells[project] = try cells[project]!.adding(contribution)
                    dayTotal = try dayTotal.adding(contribution)
                    if row.isProvisional { open.insert(project) }
                }
            }
            for (id, cell) in cells { totals[id] = try totals[id]!.adding(cell) }
            total = try total.adding(dayTotal)
            days.append(WeeklyReportDay(date: civil, bounds: dayBounds, projects: cells,
                                        openProjectIDs: open, total: dayTotal))
        }
        return WeeklyReport(bounds: bounds, timeZoneIdentifier: calendar.timeZone.identifier,
                            projects: projects, days: days, projectTotals: totals, total: total,
                            hasOpenEntry: days.contains { !$0.openProjectIDs.isEmpty })
    }

    public static func amount(seconds: Int64, project: Project) throws -> CurrencyAmount {
        try money([(project, seconds)], currency: project.currencyCode)
    }

    public static func amounts(totals: [UUID: ReportValue], projects: [Project]) throws -> [CurrencyAmount] {
        let groups = Dictionary(grouping: projects, by: \.currencyCode)
        return try groups.keys.sorted().map { code in
            try money(groups[code]!.map { ($0, totals[$0.id]?.totalSeconds ?? 0) }, currency: code)
        }
    }

    private static func money(_ contributions: [(Project, Int64)], currency: String) throws -> CurrencyAmount {
        guard Locale.commonISOCurrencyCodes.contains(currency) else { throw ReportError.unknownCurrency }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US@currency=\(currency)")
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        let precision = formatter.maximumFractionDigits
        var terms: [(digits: Digits, scale: Int)] = []
        for (project, seconds) in contributions {
            guard seconds >= 0, !project.hourlyRate.isNaN, project.hourlyRate >= 0 else {
                throw ReportError.moneyOverflow
            }
            var rate = project.hourlyRate
            let text = NSDecimalString(&rate, Locale(identifier: "en_US_POSIX"))
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count <= 2, text.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else {
                throw ReportError.moneyOverflow
            }
            let coefficient = Digits(String(parts.joined()))
            terms.append((coefficient.multiplied(by: Digits(String(seconds))),
                          (parts.count == 2 ? parts[1].count : 0) - precision))
        }
        let scale = max(0, terms.map(\.scale).max() ?? 0)
        var numerator = Digits("0")
        for term in terms { numerator.add(term.digits.shifted(scale - term.scale)) }
        // floor(N / 10^scale) has the same half-up /3600 decision: its remainder
        // reaches 1800 exactly when the full rational reaches one half.
        var quotient = numerator.dropping(scale)
        let remainder = quotient.divide(by: 3600)
        if remainder >= 1800 { quotient.add(Digits("1")) }
        return CurrencyAmount(currencyCode: currency, minorUnits: quotient.text, fractionDigits: precision)
    }
}

// Decimal supplies the rate digits; base-ten integers keep products beyond its precision exact.
private struct Digits {
    private var digits: [Int] // least significant first
    init(_ text: String) { digits = text.utf8.reversed().map { Int($0 - 48) }; normalize() }
    private init(_ digits: [Int]) { self.digits = digits; normalize() }
    private mutating func normalize() {
        while digits.count > 1 && digits.last == 0 { digits.removeLast() }
        if digits.isEmpty { digits = [0] }
    }
    var text: String { digits.reversed().map(String.init).joined() }
    func shifted(_ places: Int) -> Digits { Digits(Array(repeating: 0, count: places) + digits) }
    func dropping(_ places: Int) -> Digits { Digits(Array(digits.dropFirst(places))) }
    mutating func add(_ other: Digits) {
        var carry = 0
        for index in 0..<max(digits.count, other.digits.count) {
            if index == digits.count { digits.append(0) }
            let sum = digits[index] + (index < other.digits.count ? other.digits[index] : 0) + carry
            digits[index] = sum % 10
            carry = sum / 10
        }
        if carry > 0 { digits.append(carry) }
    }
    func multiplied(by other: Digits) -> Digits {
        var result = Array(repeating: 0, count: digits.count + other.digits.count)
        for i in digits.indices {
            for j in other.digits.indices { result[i + j] += digits[i] * other.digits[j] }
        }
        for i in 0..<(result.count - 1) { result[i + 1] += result[i] / 10; result[i] %= 10 }
        return Digits(result)
    }
    mutating func divide(by divisor: Int) -> Int {
        var remainder = 0
        for i in digits.indices.reversed() {
            let value = remainder * 10 + digits[i]
            digits[i] = value / divisor
            remainder = value % divisor
        }
        normalize()
        return remainder
    }
}
