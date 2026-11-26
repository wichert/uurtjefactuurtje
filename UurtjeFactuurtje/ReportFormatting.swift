import Foundation
import LibraryStore

enum ReportFormatting {
    static func amount(_ value: CurrencyAmount, locale: Locale = .current) -> String {
        let digits = value.minorUnits
        let places = value.fractionDigits
        guard places > 0 else { return "\(value.currencyCode) \(digits)" }
        let padded = String(repeating: "0", count: max(0, places + 1 - digits.count)) + digits
        let split = padded.index(padded.endIndex, offsetBy: -places)
        let separator = locale.decimalSeparator ?? "."
        return "\(value.currencyCode) \(padded[..<split])\(separator)\(padded[split...])"
    }

    static func duration(seconds: Int64) -> String {
        totalTime(seconds: seconds)
    }

    static func timeOfDay(
        _ timestamp: Int64,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("HHmm")
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    static func hourMark(
        _ minutesFromMidnight: Int,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let clamped = max(0, min(24 * 60, minutesFromMidnight))
        if clamped == 24 * 60 {
            return "24:00"
        }
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 1
        components.hour = clamped / 60
        components.minute = clamped % 60
        components.second = 0
        guard let date = calendar.date(from: components) else {
            let hours = String(format: "%02d", clamped / 60)
            let minutes = String(format: "%02d", clamped % 60)
            return "\(hours):\(minutes)"
        }
        return timeOfDay(Int64(date.timeIntervalSince1970), calendar: calendar, locale: locale)
    }

    static func date(
        _ timestamp: Int64,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    static func day(
        _ components: DateComponents,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        guard let resolved = calendar.date(from: components) else {
            let year = components.year.map(String.init) ?? "?"
            let month = components.month.map(String.init) ?? "?"
            let day = components.day.map(String.init) ?? "?"
            return "\(year)-\(month)-\(day)"
        }
        return date(Int64(resolved.timeIntervalSince1970), calendar: calendar, locale: locale)
    }

    static func weekdayHeader(
        _ components: DateComponents,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        guard let resolved = calendar.date(from: components) else {
            return day(components, calendar: calendar, locale: locale)
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEEd")
        return formatter.string(from: resolved)
    }

    static func instant(
        _ timestamp: Int64,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let dayPart = date(timestamp, calendar: calendar, locale: locale)
        let timePart = timeOfDay(timestamp, calendar: calendar, locale: locale)
        return "\(dayPart) \(timePart)"
    }

    static func interval(
        _ start: Int64,
        _ end: Int64,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        "\(instant(start, calendar: calendar, locale: locale)) – \(instant(end, calendar: calendar, locale: locale))"
    }
}

extension ReportFormatting {
    static func budgetHours(seconds: Decimal, locale: Locale = .current) -> String {
        var hours = seconds / 3600
        var rounded = Decimal.zero
        NSDecimalRound(&rounded, &hours, 2, .plain)
        if seconds > 0 && rounded == 0 {
            return "<\(RateInput.text(Decimal(string: "0.01")!, locale: locale)) h"
        }
        let prefix = rounded * 3600 == seconds ? "" : "≈"
        return "\(prefix)\(RateInput.text(rounded, locale: locale)) h"
    }

    static func budgetBalance(used: Decimal, budget: Int64, locale: Locale = .current) -> String {
        let difference = Decimal(budget) * 60 - used
        if difference < 0 {
            return "\(budgetHours(seconds: -difference, locale: locale)) overrun"
        }
        if difference == 0 { return "Budget reached" }
        return "\(budgetHours(seconds: difference, locale: locale)) remaining"
    }

    static func budgetAllocation(allocated: Decimal, budget: Int64, locale: Locale = .current) -> String {
        let difference = Decimal(budget) - allocated
        let balance =
            difference < 0
            ? "\(budgetHours(seconds: -difference * 60, locale: locale)) overallocated"
            : "\(budgetHours(seconds: difference * 60, locale: locale)) unallocated"
        let allocatedHours = budgetHours(seconds: allocated * 60, locale: locale)
        let budgetHours = budgetHours(seconds: Decimal(budget) * 60, locale: locale)
        return "Allocated \(allocatedHours) / \(budgetHours); \(balance)"
    }

    static func totalTime(seconds: Int64) -> String {
        let value = max(0, seconds)
        let hours = String(value / 3600)
        let minutes = String((value % 3600) / 60)
        return "\(hours.count < 2 ? "0" : "")\(hours):\(minutes.count < 2 ? "0" : "")\(minutes)"
    }
}
