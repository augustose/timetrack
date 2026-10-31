import Foundation

/// User-editable settings, read from ~/.config/timetrack/config.json.
/// The file is re-read automatically whenever it changes on disk, so edits
/// take effect without restarting the sampler.
public struct Config: Codable, Equatable {
    /// How often to take a sample, in seconds.
    public var intervalSeconds: Int
    /// No keyboard/mouse input for this long marks the sample as idle.
    public var idleThresholdSeconds: Int
    /// Master switch for recording window titles at all.
    public var recordTitles: Bool
    /// Apps whose window title is never recorded — only the app name is.
    /// Match on app name or bundle identifier, case-insensitive.
    /// A trailing `*` works as a wildcard, e.g. "com.agilebits.*".
    public var privateApps: [String]
    /// Apps that are not recorded at all — no row is written.
    public var ignoredApps: [String]
    /// Regular expressions stripped out of titles before they are stored.
    /// Each match is replaced with "…".
    public var redactPatterns: [String]
    /// Titles longer than this are truncated.
    public var maxTitleLength: Int
    /// Hour (0-23) at which a new day starts. Set to 4 if you routinely work
    /// past midnight and want 1am to count toward the previous day.
    public var dayStartHour: Int
    /// SF Symbol shown in the menu bar. See README for alternatives that read
    /// well at menu bar size. An unknown name falls back to the default.
    public var menuBarSymbol: String

    public static let `default` = Config(
        intervalSeconds: 10,
        idleThresholdSeconds: 180,
        recordTitles: true,
        privateApps: [
            "1Password",
            "Bitwarden",
            "Keychain Access",
            "Messages",
            "WhatsApp",
            "Signal",
            "Telegram",
        ],
        ignoredApps: [],
        redactPatterns: [],
        maxTitleLength: 300,
        dayStartHour: 0,
        menuBarSymbol: "stopwatch"
    )

    // Decoding tolerates a partial file: any key you leave out keeps its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.default
        intervalSeconds = try c.decodeIfPresent(Int.self, forKey: .intervalSeconds) ?? d.intervalSeconds
        idleThresholdSeconds = try c.decodeIfPresent(Int.self, forKey: .idleThresholdSeconds) ?? d.idleThresholdSeconds
        recordTitles = try c.decodeIfPresent(Bool.self, forKey: .recordTitles) ?? d.recordTitles
        privateApps = try c.decodeIfPresent([String].self, forKey: .privateApps) ?? d.privateApps
        ignoredApps = try c.decodeIfPresent([String].self, forKey: .ignoredApps) ?? d.ignoredApps
        redactPatterns = try c.decodeIfPresent([String].self, forKey: .redactPatterns) ?? d.redactPatterns
        maxTitleLength = try c.decodeIfPresent(Int.self, forKey: .maxTitleLength) ?? d.maxTitleLength
        dayStartHour = try c.decodeIfPresent(Int.self, forKey: .dayStartHour) ?? d.dayStartHour
        menuBarSymbol = try c.decodeIfPresent(String.self, forKey: .menuBarSymbol) ?? d.menuBarSymbol
    }

    public init(intervalSeconds: Int, idleThresholdSeconds: Int, recordTitles: Bool,
                privateApps: [String], ignoredApps: [String], redactPatterns: [String],
                maxTitleLength: Int, dayStartHour: Int, menuBarSymbol: String) {
        self.intervalSeconds = intervalSeconds
        self.idleThresholdSeconds = idleThresholdSeconds
        self.recordTitles = recordTitles
        self.privateApps = privateApps
        self.ignoredApps = ignoredApps
        self.redactPatterns = redactPatterns
        self.maxTitleLength = maxTitleLength
        self.dayStartHour = dayStartHour
        self.menuBarSymbol = menuBarSymbol
    }

    /// Values outside a sane range would quietly break sampling, so clamp them.
    public var sanitized: Config {
        var c = self
        c.intervalSeconds = min(max(c.intervalSeconds, 1), 3600)
        c.idleThresholdSeconds = max(c.idleThresholdSeconds, 0)
        c.maxTitleLength = min(max(c.maxTitleLength, 20), 4000)
        c.dayStartHour = min(max(c.dayStartHour, 0), 23)
        if c.menuBarSymbol.trimmingCharacters(in: .whitespaces).isEmpty {
            c.menuBarSymbol = Config.default.menuBarSymbol
        }
        return c
    }

    // MARK: - Matching

    private static func matches(_ patterns: [String], name: String, bundleId: String) -> Bool {
        let candidates = [name.lowercased(), bundleId.lowercased()].filter { !$0.isEmpty }
        for raw in patterns {
            let p = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !p.isEmpty else { continue }
            if p.hasSuffix("*") {
                let prefix = String(p.dropLast())
                if candidates.contains(where: { $0.hasPrefix(prefix) }) { return true }
            } else if candidates.contains(p) {
                return true
            }
        }
        return false
    }

    public func isIgnored(name: String, bundleId: String) -> Bool {
        Config.matches(ignoredApps, name: name, bundleId: bundleId)
    }

    public func isPrivate(name: String, bundleId: String) -> Bool {
        Config.matches(privateApps, name: name, bundleId: bundleId)
    }

    /// Apply redaction patterns and the length cap to a raw window title.
    public func clean(title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        for pattern in redactPatterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            t = re.stringByReplacingMatches(
                in: t, options: [], range: NSRange(t.startIndex..., in: t), withTemplate: "…"
            )
        }
        if t.count > maxTitleLength {
            t = String(t.prefix(maxTitleLength)) + "…"
        }
        return t
    }
}

/// Loads the config and reloads it when the file changes on disk.
public final class ConfigStore {
    private var cached: Config
    private var cachedStamp: Date?
    private let url: URL

    public init(url: URL = Paths.configFile) {
        self.url = url
        self.cached = ConfigStore.read(url)?.sanitized ?? Config.default
        self.cachedStamp = ConfigStore.modified(url)
    }

    /// Current config, re-read if the file's modification date moved.
    public var current: Config {
        let stamp = ConfigStore.modified(url)
        if stamp != cachedStamp {
            cachedStamp = stamp
            if let fresh = ConfigStore.read(url) {
                cached = fresh.sanitized
            }
        }
        return cached
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private static func read(_ url: URL) -> Config? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    /// Write the default config file if none exists yet. Returns true if it created one.
    @discardableResult
    public static func createDefaultIfMissing(at url: URL = Paths.configFile) -> Bool {
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Config.default) else { return false }
        try? data.write(to: url)
        return true
    }
}
