import Foundation

/// One 10-second observation of what was in front of you.
public struct Sample: Equatable {
    public let ts: Date
    public let day: String
    public let app: String
    public let bundleId: String
    public let title: String
    public let idle: Bool
    public let intervalSeconds: Int

    public init(ts: Date, day: String, app: String, bundleId: String,
                title: String, idle: Bool, intervalSeconds: Int) {
        self.ts = ts
        self.day = day
        self.app = app
        self.bundleId = bundleId
        self.title = title
        self.idle = idle
        self.intervalSeconds = intervalSeconds
    }
}

public struct AppTotal: Equatable {
    public let app: String
    public let bundleId: String
    public let seconds: Int
    public let samples: Int
}

public struct TitleTotal: Equatable {
    public let app: String
    public let title: String
    public let seconds: Int
    public let samples: Int
}

/// A run of consecutive samples that belong to the same thing, collapsed into a block.
public struct Session: Equatable {
    public let start: Date
    public let end: Date
    public let app: String
    public let title: String
    public let seconds: Int
}

/// Turning wall-clock time into the "day" a sample belongs to, honouring
/// `dayStartHour` so late-night work lands on the right date.
public enum DayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func string(for date: Date, dayStartHour: Int) -> String {
        let shifted = date.addingTimeInterval(-Double(dayStartHour) * 3600)
        return formatter.string(from: shifted)
    }

    public static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }

    public static func today(dayStartHour: Int) -> String {
        string(for: Date(), dayStartHour: dayStartHour)
    }

    /// The half-open [start, end) wall-clock range covered by a `yyyy-MM-dd` key.
    public static func range(for day: String, dayStartHour: Int) -> (start: Date, end: Date)? {
        guard let midnight = date(from: day) else { return nil }
        let start = midnight.addingTimeInterval(Double(dayStartHour) * 3600)
        return (start, start.addingTimeInterval(86400))
    }

    /// Shift a day key by a number of days.
    public static func offset(_ day: String, by days: Int) -> String? {
        guard let d = date(from: day) else { return nil }
        return formatter.string(from: d.addingTimeInterval(Double(days) * 86400))
    }
}

/// "6h 12m", "45m", "20s" — the format used everywhere in reports.
public func formatDuration(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
    return "\(m)m"
}

/// Decimal hours rounded to two places, for pasting into a timesheet.
public func decimalHours(_ seconds: Int) -> String {
    String(format: "%.2f", Double(seconds) / 3600.0)
}

/// "3 hours 12 minutes" — spelled out for VoiceOver, which reads "3h 12m" poorly.
public func spokenDuration(_ seconds: Int) -> String {
    if seconds < 60 {
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    var parts: [String] = []
    if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
    if minutes > 0 { parts.append(minutes == 1 ? "1 minute" : "\(minutes) minutes") }
    return parts.isEmpty ? "0 minutes" : parts.joined(separator: " ")
}
