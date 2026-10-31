import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StoreError: Error, CustomStringConvertible {
    case open(String)
    case exec(String)
    case prepare(String)

    public var description: String {
        switch self {
        case .open(let m): return "could not open database: \(m)"
        case .exec(let m): return "database error: \(m)"
        case .prepare(let m): return "could not prepare statement: \(m)"
        }
    }
}

/// SQLite-backed sample store. WAL mode is on so the menu bar app and the CLI
/// can read while the sampler writes.
public final class Store {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ca.senet.timetrack.store")

    public init(url: URL = Paths.database, readOnly: Bool = false) throws {
        // Read-only against a database that does not exist yet just fails, and a
        // first run should not error out — create it instead.
        let exists = FileManager.default.fileExists(atPath: url.path)
        let effectivelyReadOnly = readOnly && exists
        let flags = effectivelyReadOnly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(url.path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw StoreError.open(msg)
        }
        sqlite3_busy_timeout(db, 3000)
        if !effectivelyReadOnly {
            try exec("PRAGMA journal_mode=WAL;")
            try exec("PRAGMA synchronous=NORMAL;")
            try migrate()
        }
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.exec(msg)
        }
    }

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS samples (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            ts         INTEGER NOT NULL,
            day        TEXT    NOT NULL,
            app        TEXT    NOT NULL,
            bundle_id  TEXT    NOT NULL DEFAULT '',
            title      TEXT    NOT NULL DEFAULT '',
            idle       INTEGER NOT NULL DEFAULT 0,
            interval_s INTEGER NOT NULL DEFAULT 10
        );
        CREATE INDEX IF NOT EXISTS idx_samples_ts  ON samples(ts);
        CREATE INDEX IF NOT EXISTS idx_samples_day ON samples(day);
        CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
    }

    // MARK: - Statement helper

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw StoreError.prepare(msg)
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: Int) {
        sqlite3_bind_int64(stmt, index, Int64(value))
    }

    private func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, column) else { return "" }
        return String(cString: c)
    }

    // MARK: - Writes

    public func insert(_ sample: Sample) throws {
        try queue.sync {
            let stmt = try prepare("""
                INSERT INTO samples (ts, day, app, bundle_id, title, idle, interval_s)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, Int(sample.ts.timeIntervalSince1970.rounded()))
            bind(stmt, 2, sample.day)
            bind(stmt, 3, sample.app)
            bind(stmt, 4, sample.bundleId)
            bind(stmt, 5, sample.title)
            bind(stmt, 6, sample.idle ? 1 : 0)
            bind(stmt, 7, sample.intervalSeconds)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    @discardableResult
    public func prune(before date: Date) throws -> Int {
        try queue.sync {
            let stmt = try prepare("DELETE FROM samples WHERE ts < ?;")
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, Int(date.timeIntervalSince1970.rounded()))
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
            return Int(sqlite3_changes(db))
        }
    }

    // MARK: - Reads

    /// Raw samples in a time range, oldest first.
    public func samples(from: Date, to: Date, includeIdle: Bool = false) throws -> [Sample] {
        try queue.sync {
            var sql = "SELECT ts, day, app, bundle_id, title, idle, interval_s FROM samples WHERE ts >= ? AND ts < ?"
            if !includeIdle { sql += " AND idle = 0" }
            sql += " ORDER BY ts ASC;"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, Int(from.timeIntervalSince1970.rounded()))
            bind(stmt, 2, Int(to.timeIntervalSince1970.rounded()))
            var out: [Sample] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(Sample(
                    ts: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 0))),
                    day: text(stmt, 1),
                    app: text(stmt, 2),
                    bundleId: text(stmt, 3),
                    title: text(stmt, 4),
                    idle: sqlite3_column_int64(stmt, 5) != 0,
                    intervalSeconds: Int(sqlite3_column_int64(stmt, 6))
                ))
            }
            return out
        }
    }

    /// Time per application, biggest first.
    public func appTotals(from: Date, to: Date, includeIdle: Bool = false) throws -> [AppTotal] {
        try queue.sync {
            var sql = """
                SELECT app,
                       COALESCE(MAX(bundle_id), ''),
                       SUM(interval_s),
                       COUNT(*)
                FROM samples
                WHERE ts >= ? AND ts < ?
                """
            if !includeIdle { sql += " AND idle = 0" }
            sql += " GROUP BY app ORDER BY SUM(interval_s) DESC;"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, Int(from.timeIntervalSince1970.rounded()))
            bind(stmt, 2, Int(to.timeIntervalSince1970.rounded()))
            var out: [AppTotal] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(AppTotal(
                    app: text(stmt, 0),
                    bundleId: text(stmt, 1),
                    seconds: Int(sqlite3_column_int64(stmt, 2)),
                    samples: Int(sqlite3_column_int64(stmt, 3))
                ))
            }
            return out
        }
    }

    /// Time per window title, biggest first. Optionally limited to one app.
    public func titleTotals(from: Date, to: Date, app: String? = nil,
                            includeIdle: Bool = false, limit: Int = 0) throws -> [TitleTotal] {
        try queue.sync {
            var sql = """
                SELECT app, title, SUM(interval_s), COUNT(*)
                FROM samples
                WHERE ts >= ? AND ts < ? AND title <> ''
                """
            if !includeIdle { sql += " AND idle = 0" }
            if app != nil { sql += " AND app = ?" }
            sql += " GROUP BY app, title ORDER BY SUM(interval_s) DESC"
            if limit > 0 { sql += " LIMIT \(limit)" }
            sql += ";"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, Int(from.timeIntervalSince1970.rounded()))
            bind(stmt, 2, Int(to.timeIntervalSince1970.rounded()))
            if let app { bind(stmt, 3, app) }
            var out: [TitleTotal] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(TitleTotal(
                    app: text(stmt, 0),
                    title: text(stmt, 1),
                    seconds: Int(sqlite3_column_int64(stmt, 2)),
                    samples: Int(sqlite3_column_int64(stmt, 3))
                ))
            }
            return out
        }
    }

    /// Consecutive samples collapsed into blocks — the chronological view you
    /// actually reconstruct a timesheet from.
    ///
    /// - Parameter byTitle: split blocks when the window title changes, not just the app.
    public func sessions(from: Date, to: Date, includeIdle: Bool = false,
                         byTitle: Bool = true) throws -> [Session] {
        let rows = try samples(from: from, to: to, includeIdle: includeIdle)
        var sessions: [Session] = []
        var current: (start: Date, end: Date, app: String, title: String, seconds: Int)?

        for row in rows {
            let sameThing = current.map {
                $0.app == row.app && (!byTitle || $0.title == row.title)
            } ?? false
            // A gap longer than three intervals means the sampler was off (sleep,
            // logout, pause) — start a new block rather than papering over it.
            let contiguous = current.map {
                row.ts.timeIntervalSince($0.end) <= Double(row.intervalSeconds * 3)
            } ?? false

            if sameThing && contiguous, var c = current {
                c.end = row.ts
                c.seconds += row.intervalSeconds
                current = c
            } else {
                if let c = current {
                    sessions.append(Session(start: c.start, end: c.end, app: c.app,
                                            title: c.title, seconds: c.seconds))
                }
                current = (row.ts, row.ts, row.app, row.title, row.intervalSeconds)
            }
        }
        if let c = current {
            sessions.append(Session(start: c.start, end: c.end, app: c.app,
                                    title: c.title, seconds: c.seconds))
        }
        return sessions
    }

    public func totalSeconds(from: Date, to: Date, includeIdle: Bool = false) throws -> Int {
        try appTotals(from: from, to: to, includeIdle: includeIdle)
            .reduce(0) { $0 + $1.seconds }
    }

    public struct Stats {
        public let sampleCount: Int
        public let first: Date?
        public let last: Date?
        public let days: Int

        public init(sampleCount: Int, first: Date?, last: Date?, days: Int) {
            self.sampleCount = sampleCount
            self.first = first
            self.last = last
            self.days = days
        }
    }

    public func stats() throws -> Stats {
        try queue.sync {
            let stmt = try prepare("SELECT COUNT(*), MIN(ts), MAX(ts), COUNT(DISTINCT day) FROM samples;")
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return Stats(sampleCount: 0, first: nil, last: nil, days: 0)
            }
            let count = Int(sqlite3_column_int64(stmt, 0))
            let first = sqlite3_column_type(stmt, 1) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1)))
            let last = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2)))
            return Stats(sampleCount: count, first: first, last: last,
                         days: Int(sqlite3_column_int64(stmt, 3)))
        }
    }
}
