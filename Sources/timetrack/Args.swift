import Foundation
import TimeTrackCore

/// Minimal flag parser — no external dependencies, so the package builds offline.
struct Args {
    let command: String
    private var flags: [String: String] = [:]
    private var switches: Set<String> = []
    private(set) var positional: [String] = []

    init(_ argv: [String]) {
        var rest = argv
        command = rest.first.map { $0.hasPrefix("-") ? "help" : $0 } ?? "help"
        if !rest.isEmpty && !rest[0].hasPrefix("-") { rest.removeFirst() }

        var i = 0
        while i < rest.count {
            let token = rest[i]
            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    flags[String(body[body.startIndex..<eq])] = String(body[body.index(after: eq)...])
                } else if i + 1 < rest.count && Args.isValue(rest[i + 1]) {
                    flags[body] = rest[i + 1]
                    i += 1
                } else {
                    switches.insert(body)
                }
            } else if Args.isValue(token) {
                positional.append(token)
            } else if token.count > 1 {
                let body = String(token.dropFirst())
                if i + 1 < rest.count && Args.isValue(rest[i + 1]) {
                    flags[body] = rest[i + 1]
                    i += 1
                } else {
                    switches.insert(body)
                }
            } else {
                positional.append(token)
            }
            i += 1
        }
    }

    /// A token is a value rather than a flag unless it starts with "-".
    /// Negative day offsets ("-3") are the exception — they are values.
    private static func isValue(_ token: String) -> Bool {
        !token.hasPrefix("-") || Int(token) != nil
    }

    func string(_ name: String, _ alias: String? = nil) -> String? {
        flags[name] ?? alias.flatMap { flags[$0] }
    }

    func int(_ name: String) -> Int? {
        string(name).flatMap { Int($0) }
    }

    func has(_ name: String, _ alias: String? = nil) -> Bool {
        switches.contains(name)
            || flags[name] != nil
            || (alias.map { switches.contains($0) || flags[$0] != nil } ?? false)
    }

    /// "90s", "5m", "2h", or a bare number of seconds.
    func duration(_ name: String) -> Int? {
        guard let raw = string(name)?.lowercased() else { return nil }
        if let plain = Int(raw) { return plain }
        let value = Double(raw.dropLast()) ?? 0
        switch raw.last {
        case "s": return Int(value)
        case "m": return Int(value * 60)
        case "h": return Int(value * 3600)
        default:  return nil
        }
    }
}

/// The time window a report covers, plus a label for the header.
struct ReportRange {
    let from: Date
    let to: Date
    let label: String
}

enum RangeResolver {
    /// Accepts: today, yesterday, a `yyyy-MM-dd` date, or a negative day offset like -3.
    static func day(_ token: String, config: Config) -> String? {
        let t = token.trimmingCharacters(in: .whitespaces).lowercased()
        switch t {
        case "today", "hoy", "aujourd'hui":
            return DayKey.today(dayStartHour: config.dayStartHour)
        case "yesterday", "ayer", "hier":
            return DayKey.offset(DayKey.today(dayStartHour: config.dayStartHour), by: -1)
        default:
            if let offset = Int(t), offset <= 0 {
                return DayKey.offset(DayKey.today(dayStartHour: config.dayStartHour), by: offset)
            }
            return DayKey.date(from: t) != nil ? t : nil
        }
    }

    static func resolve(_ args: Args, config: Config, defaultDay: String? = nil) -> ReportRange? {
        if let fromToken = args.string("from"), let toToken = args.string("to") {
            guard let fromDay = day(fromToken, config: config),
                  let toDay = day(toToken, config: config),
                  let start = DayKey.range(for: fromDay, dayStartHour: config.dayStartHour),
                  let end = DayKey.range(for: toDay, dayStartHour: config.dayStartHour)
            else { return nil }
            return ReportRange(from: start.start, to: end.end, label: "\(fromDay) → \(toDay)")
        }

        if args.has("week") {
            let today = DayKey.today(dayStartHour: config.dayStartHour)
            guard let firstDay = DayKey.offset(today, by: -6),
                  let start = DayKey.range(for: firstDay, dayStartHour: config.dayStartHour),
                  let end = DayKey.range(for: today, dayStartHour: config.dayStartHour)
            else { return nil }
            return ReportRange(from: start.start, to: end.end, label: "\(firstDay) → \(today) (7 days)")
        }

        let token = args.string("day", "d") ?? args.positional.first ?? defaultDay ?? "today"
        guard let resolved = day(token, config: config),
              let bounds = DayKey.range(for: resolved, dayStartHour: config.dayStartHour)
        else { return nil }
        return ReportRange(from: bounds.start, to: bounds.end, label: resolved)
    }
}
