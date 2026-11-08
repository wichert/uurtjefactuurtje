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
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remaining = seconds % 60
        return "\(hours) h \(minutes) min \(remaining) sec (\(seconds) seconds)"
    }

    static func day(_ date: DateComponents, calendar: Calendar) -> String {
        let year = date.year.map(String.init) ?? "?"
        let month = date.month.map(String.init) ?? "?"
        let day = date.day.map(String.init) ?? "?"
        return "\(year)-\(month)-\(day)"
    }

    static func instant(_ timestamp: Int64, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    static func interval(_ start: Int64, _ end: Int64, calendar: Calendar) -> String {
        "\(instant(start, calendar: calendar)) – \(instant(end, calendar: calendar))"
    }
}
