import Foundation
import TimeTrackCore

enum Render {
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    static func truncate(_ s: String, _ width: Int) -> String {
        s.count <= width ? s : String(s.prefix(width - 1)) + "…"
    }

    static func header(_ title: String) {
        print("")
        print(title)
        print(String(repeating: "─", count: min(title.count, 72)))
    }

    /// App totals with duration, decimal hours and share of the day.
    static func appTable(_ totals: [AppTotal], total: Int, minSeconds: Int) {
        let shown = totals.filter { $0.seconds >= minSeconds }
        guard !shown.isEmpty else {
            print("No activity recorded for this range.")
            return
        }
        let nameWidth = min(max(shown.map(\.app.count).max() ?? 10, 10), 36)
        print(pad("APP", nameWidth) + "  " + pad("TIME", 10) + pad("HOURS", 8) + "SHARE")
        for row in shown {
            let share = total > 0 ? Double(row.seconds) / Double(total) * 100 : 0
            print(
                pad(truncate(row.app, nameWidth), nameWidth) + "  "
                + pad(formatDuration(row.seconds), 10)
                + pad(decimalHours(row.seconds), 8)
                + String(format: "%.1f%%", share)
            )
        }
        print("")
        print(pad("TOTAL", nameWidth) + "  "
              + pad(formatDuration(total), 10)
              + pad(decimalHours(total), 8))
    }

    static func titleTable(_ totals: [TitleTotal], minSeconds: Int, showApp: Bool) {
        let shown = totals.filter { $0.seconds >= minSeconds }
        guard !shown.isEmpty else {
            print("No window titles recorded for this range.")
            return
        }
        for row in shown {
            let prefix = showApp ? "\(row.app) — " : ""
            print(pad(formatDuration(row.seconds), 9)
                  + pad(decimalHours(row.seconds), 8)
                  + truncate(prefix + row.title, 90))
        }
    }

    /// Chronological blocks — the view you rebuild a timesheet from.
    static func sessionList(_ sessions: [Session], minSeconds: Int) {
        let shown = sessions.filter { $0.seconds >= minSeconds }
        guard !shown.isEmpty else {
            print("No blocks longer than \(formatDuration(minSeconds)) in this range.")
            return
        }
        for s in shown {
            let window = "\(clock.string(from: s.start))–\(clock.string(from: s.end))"
            let label = s.title.isEmpty ? s.app : "\(s.app) — \(s.title)"
            print(pad(window, 13)
                  + pad(formatDuration(s.seconds), 9)
                  + truncate(label, 88))
        }
        let total = shown.reduce(0) { $0 + $1.seconds }
        print("")
        print("\(shown.count) blocks, \(formatDuration(total)) (\(decimalHours(total)) h)")
    }

    static func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
