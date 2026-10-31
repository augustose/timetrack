import Foundation
import TimeTrackCore

let args = Args(Array(CommandLine.arguments.dropFirst()))
let configStore = ConfigStore()
ConfigStore.createDefaultIfMissing()
let config = configStore.current

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("timetrack: " + message + "\n").utf8))
    exit(1)
}

func openStore(readOnly: Bool = false) -> Store {
    do {
        return try Store(readOnly: readOnly)
    } catch {
        fail("\(error)")
    }
}

func range(defaultDay: String? = nil) -> ReportRange {
    guard let r = RangeResolver.resolve(args, config: config, defaultDay: defaultDay) else {
        fail("could not understand that date. Use today, yesterday, -3, or 2026-09-10.")
    }
    return r
}

// MARK: - Commands

var signalSources: [DispatchSourceSignal] = []

func cmdRun() {
    switch Recorder.runningPID() {
    case .some(let pid):
        fail("a sampler is already running (pid \(pid)). Stop it first.")
    case .none:
        break
    }
    if !Sampler.hasAccessibilityPermission() {
        print("Accessibility permission is not granted yet.")
        print("Window titles will be blank until you allow it.")
        print("Opening the prompt — approve 'timetrack', then run this again.")
        Sampler.requestAccessibilityPermission()
    }

    let store = openStore()
    let recorder = Recorder(store: store, configStore: configStore)
    recorder.onError = { message in
        FileHandle.standardError.write(Data(("timetrack: \(message)\n").utf8))
    }
    if args.has("verbose", "v") {
        recorder.onSample = { s in
            let mark = s.idle ? " [idle]" : ""
            print("\(Render.stamp.string(from: s.ts))  \(s.app)\(mark)  \(s.title)")
            fflush(stdout)
        }
    }

    switch recorder.start(requirePermission: false) {
    case .alreadyRunning(let pid):
        fail("a sampler is already running (pid \(pid)).")
    case .missingPermission:
        fail("accessibility permission is required.")
    case .started:
        break
    }

    print("timetrack: sampling every \(config.intervalSeconds)s → \(Paths.database.path)")
    if Recorder.isPaused { print("timetrack: currently PAUSED (run `timetrack resume`)") }
    fflush(stdout)

    // Clean shutdown so the lock file does not go stale.
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            recorder.stop()
            print("\ntimetrack: stopped.")
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }

    RunLoop.main.run()
}

func cmdStatus() {
    let store = openStore()
    let stats = (try? store.stats()) ?? Store.Stats(sampleCount: 0, first: nil, last: nil, days: 0)

    Render.header("timetrack status")
    if let pid = Recorder.runningPID() {
        print("Sampler:      running (pid \(pid))")
    } else {
        print("Sampler:      not running")
    }
    print("Paused:       \(Recorder.isPaused ? "yes" : "no")")
    print("Accessibility:\(Sampler.hasAccessibilityPermission() ? " granted" : " NOT granted — titles will be blank")")
    print("Interval:     \(config.intervalSeconds)s")
    print("Idle after:   \(config.idleThresholdSeconds)s")
    print("Database:     \(Paths.database.path)")
    print("Config:       \(Paths.configFile.path)")
    print("Samples:      \(stats.sampleCount) across \(stats.days) days")
    if let first = stats.first { print("First sample: \(Render.stamp.string(from: first))") }
    if let last = stats.last { print("Last sample:  \(Render.stamp.string(from: last))") }

    let today = DayKey.today(dayStartHour: config.dayStartHour)
    if let bounds = DayKey.range(for: today, dayStartHour: config.dayStartHour),
       let seconds = try? store.totalSeconds(from: bounds.start, to: bounds.end) {
        print("Today:        \(formatDuration(seconds)) (\(decimalHours(seconds)) h)")
    }
}

func cmdReport(defaultDay: String?) {
    let r = range(defaultDay: defaultDay)
    let store = openStore()
    let includeIdle = args.has("include-idle")
    let minSeconds = args.duration("min") ?? 60

    guard let totals = try? store.appTotals(from: r.from, to: r.to, includeIdle: includeIdle) else {
        fail("could not read the database.")
    }
    let total = totals.reduce(0) { $0 + $1.seconds }

    Render.header("Activity — \(r.label)\(includeIdle ? " (including idle)" : "")")
    Render.appTable(totals, total: total, minSeconds: minSeconds)

    if args.has("titles", "t") {
        let titles = try? store.titleTotals(from: r.from, to: r.to,
                                            includeIdle: includeIdle,
                                            limit: args.int("limit") ?? 40)
        Render.header("Top window titles")
        Render.titleTable(titles ?? [], minSeconds: minSeconds, showApp: true)
    }
}

func cmdSessions() {
    let r = range()
    let store = openStore()
    let includeIdle = args.has("include-idle")
    let minSeconds = args.duration("min") ?? 300
    let byTitle = !args.has("by-app")

    guard let sessions = try? store.sessions(from: r.from, to: r.to,
                                             includeIdle: includeIdle, byTitle: byTitle)
    else { fail("could not read the database.") }

    Render.header("Blocks — \(r.label) (\(formatDuration(minSeconds)) or longer)")
    Render.sessionList(sessions, minSeconds: minSeconds)
}

func cmdExport() {
    let r = range()
    let store = openStore()
    let includeIdle = args.has("include-idle")
    let asSessions = args.has("sessions")

    var lines: [String] = []
    if asSessions {
        let minSeconds = args.duration("min") ?? 0
        let sessions = (try? store.sessions(from: r.from, to: r.to,
                                            includeIdle: includeIdle,
                                            byTitle: !args.has("by-app"))) ?? []
        lines.append("start,end,minutes,hours,app,title")
        for s in sessions where s.seconds >= minSeconds {
            lines.append([
                Render.stamp.string(from: s.start),
                Render.stamp.string(from: s.end),
                String(s.seconds / 60),
                decimalHours(s.seconds),
                Render.csvEscape(s.app),
                Render.csvEscape(s.title),
            ].joined(separator: ","))
        }
    } else {
        let samples = (try? store.samples(from: r.from, to: r.to, includeIdle: includeIdle)) ?? []
        lines.append("timestamp,day,app,bundle_id,title,idle,interval_s")
        for s in samples {
            lines.append([
                Render.stamp.string(from: s.ts),
                s.day,
                Render.csvEscape(s.app),
                Render.csvEscape(s.bundleId),
                Render.csvEscape(s.title),
                s.idle ? "1" : "0",
                String(s.intervalSeconds),
            ].joined(separator: ","))
        }
    }

    let text = lines.joined(separator: "\n") + "\n"
    if let out = args.string("output", "o") {
        let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            print("Wrote \(lines.count - 1) rows to \(url.path)")
        } catch {
            fail("could not write \(url.path): \(error)")
        }
    } else {
        print(text, terminator: "")
    }
}

func cmdPause() {
    Recorder.pause()
    print("Sampling paused. Run `timetrack resume` to start recording again.")
}

func cmdResume() {
    Recorder.resume()
    print("Sampling resumed.")
}

func cmdConfig() {
    if args.has("path") {
        print(Paths.configFile.path)
        return
    }
    if args.has("edit") {
        let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "open"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = [editor, Paths.configFile.path]
        try? task.run()
        task.waitUntilExit()
        return
    }
    print("Config file: \(Paths.configFile.path)\n")
    if let data = try? Data(contentsOf: Paths.configFile),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

func cmdPermission() {
    if Sampler.hasAccessibilityPermission() {
        print("Accessibility permission: granted. Window titles are being recorded.")
        return
    }
    print("Accessibility permission: NOT granted.")
    print("Without it the app name is still recorded, but window titles stay blank.")
    print("Opening System Settings — add and enable this binary, then try again.")
    Sampler.requestAccessibilityPermission()
    Sampler.openAccessibilitySettings()
}

func cmdPrune() {
    guard let days = args.int("older-than") else {
        fail("prune needs --older-than DAYS, e.g. `timetrack prune --older-than 90`.")
    }
    let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
    let store = openStore()
    do {
        let removed = try store.prune(before: cutoff)
        print("Removed \(removed) samples older than \(days) days.")
    } catch {
        fail("\(error)")
    }
}

func cmdHelp() {
    print("""
    timetrack — logs the frontmost window every few seconds so you can rebuild a timesheet.

    USAGE
      timetrack <command> [options]

    COMMANDS
      run                  Start sampling in the foreground (this is what launchd runs)
      status               Sampler state, permission, database stats, time so far today
      today                Time per app for today
      report [day]         Time per app for a day or range
      sessions [day]       Chronological blocks — the timesheet view
      export [day]         CSV to stdout, or to a file with -o
      pause / resume       Stop and restart recording without killing the sampler
      config               Show the config file (--path, --edit)
      permission           Check or request Accessibility permission
      prune --older-than N Delete samples older than N days
      help                 This text

    DATE OPTIONS  (report, sessions, export)
      --day today | yesterday | 2026-09-10 | -3
      --week                     Last 7 days
      --from A --to B            Explicit range, same date formats

    OTHER OPTIONS
      --titles, -t         Also list time per window title
      --min 5m             Hide anything shorter (default 1m for report, 5m for sessions)
      --include-idle       Count samples taken while you were away
      --by-app             Group blocks by app only, ignoring title changes
      --sessions           With export: write blocks instead of raw samples
      -o FILE              With export: write to a file
      --verbose, -v        With run: print every sample as it is taken

    EXAMPLES
      timetrack sessions --day yesterday --min 10m
      timetrack report --week --titles
      timetrack export --day today --sessions -o ~/Desktop/today.csv
    """)
}

// MARK: - Dispatch

switch args.command {
case "run":                 cmdRun()
case "status":              cmdStatus()
case "today":               cmdReport(defaultDay: "today")
case "yesterday":           cmdReport(defaultDay: "yesterday")
case "report":              cmdReport(defaultDay: nil)
case "sessions", "blocks":  cmdSessions()
case "export":              cmdExport()
case "pause":               cmdPause()
case "resume":              cmdResume()
case "config":              cmdConfig()
case "permission", "perms": cmdPermission()
case "prune":               cmdPrune()
case "help", "-h", "--help": cmdHelp()
default:
    FileHandle.standardError.write(Data("timetrack: unknown command '\(args.command)'\n\n".utf8))
    cmdHelp()
    exit(1)
}
