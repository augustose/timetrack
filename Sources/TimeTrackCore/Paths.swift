import Foundation

/// Every on-disk location TimeTrack uses. Nothing leaves the machine.
public enum Paths {
    private static let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// ~/.local/share/timetrack — the SQLite database lives here.
    public static var dataDir: URL {
        ensure(home.appendingPathComponent(".local/share/timetrack", isDirectory: true))
    }

    /// ~/.config/timetrack — user-editable config.
    public static var configDir: URL {
        ensure(home.appendingPathComponent(".config/timetrack", isDirectory: true))
    }

    /// ~/.local/state/timetrack — runtime state: lock, pause flag, logs.
    public static var stateDir: URL {
        ensure(home.appendingPathComponent(".local/state/timetrack", isDirectory: true))
    }

    public static var database: URL { dataDir.appendingPathComponent("track.db") }
    public static var configFile: URL { configDir.appendingPathComponent("config.json") }
    public static var pauseFlag: URL { stateDir.appendingPathComponent("paused") }
    public static var lockFile: URL { stateDir.appendingPathComponent("sampler.lock") }
    public static var logFile: URL { stateDir.appendingPathComponent("timetrack.log") }
    public static var errorLogFile: URL { stateDir.appendingPathComponent("timetrack.err.log") }
}
