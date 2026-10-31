import AppKit
import TimeTrackCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var recorder: Recorder?
    private var store: Store?
    private var refreshTimer: Timer?
    private let configStore = ConfigStore()

    /// True when another process (the CLI daemon) already holds the sampling
    /// lock — we then act as a viewer only.
    private var viewerOnly = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ConfigStore.createDefaultIfMissing()

        do {
            store = try Store()
        } catch {
            presentFatal("Could not open the database at \(Paths.database.path).\n\n\(error)")
            return
        }

        setUpStatusItem()
        startSampling()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateStatusTitle()
        }
        updateStatusTitle()

        if !Sampler.hasAccessibilityPermission() {
            promptForAccessibility()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder?.stop()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The menu bar item carries three states, and each one has to be readable
    /// at a glance in a crowded menu bar: recording, paused, and "permission
    /// missing" — the last one is a different glyph entirely, not a subtle badge,
    /// because a badge is illegible at 16 points.
    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        let config = configStore.current

        var seconds = 0
        if let store,
           let bounds = DayKey.range(for: DayKey.today(dayStartHour: config.dayStartHour),
                                     dayStartHour: config.dayStartHour),
           let total = try? store.totalSeconds(from: bounds.start, to: bounds.end) {
            seconds = total
        }

        let paused = Recorder.isPaused
        let missingPermission = !Sampler.hasAccessibilityPermission()

        let symbolName = missingPermission ? "exclamationmark.triangle.fill" : config.menuBarSymbol
        let image = AppDelegate.symbolImage(symbolName)
        image?.isTemplate = true
        button.image = image

        // Dimming is how the menu bar natively says "this is off" — it survives
        // dark mode, tinting and the reduce-transparency setting.
        button.appearsDisabled = paused && !missingPermission

        let state: String
        if missingPermission {
            state = "needs Accessibility permission"
            button.title = " !"
        } else if paused {
            state = "paused"
            button.title = " paused"
        } else {
            state = "recording"
            button.title = " " + formatDuration(seconds)
        }

        // "3h 12m" is read aloud badly, so VoiceOver gets the spelled-out form.
        let spoken = "TimeTrack, \(state), \(spokenDuration(seconds)) recorded today"
        button.toolTip = spoken
        button.setAccessibilityLabel(spoken)
    }

    /// Falls back to the built-in symbol if the configured name is not a real
    /// SF Symbol on this macOS version — a typo should not leave a blank button.
    private static func symbolImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: "TimeTrack")
            ?? NSImage(systemSymbolName: Config.default.menuBarSymbol,
                       accessibilityDescription: "TimeTrack")
    }

    // MARK: - Sampling

    private func startSampling() {
        guard let store else { return }
        let recorder = Recorder(store: store, configStore: configStore)
        switch recorder.start(requirePermission: false) {
        case .started:
            self.recorder = recorder
            viewerOnly = false
        case .alreadyRunning:
            // The CLI daemon is doing the work; we just display it.
            viewerOnly = true
        case .missingPermission:
            viewerOnly = false
        }
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        updateStatusTitle()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let config = configStore.current

        // Header: today's total.
        let today = DayKey.today(dayStartHour: config.dayStartHour)
        let bounds = DayKey.range(for: today, dayStartHour: config.dayStartHour)
        var totals: [AppTotal] = []
        var total = 0
        if let store, let bounds {
            totals = (try? store.appTotals(from: bounds.start, to: bounds.end)) ?? []
            total = totals.reduce(0) { $0 + $1.seconds }
        }

        addDisabled("Today — \(formatDuration(total)) (\(decimalHours(total)) h)")

        if totals.isEmpty {
            addDisabled("No activity recorded yet")
        } else {
            for row in totals.prefix(6) {
                addDisabled("   \(formatDuration(row.seconds).padded(to: 8))\(row.app)")
            }
        }

        menu.addItem(.separator())

        // State.
        if !Sampler.hasAccessibilityPermission() {
            let item = NSMenuItem(title: "⚠︎  Grant Accessibility permission…",
                                  action: #selector(openAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if viewerOnly {
            addDisabled("Recording handled by the timetrack daemon")
        }

        let pauseItem = NSMenuItem(
            title: Recorder.isPaused ? "Resume recording" : "Pause recording",
            action: #selector(togglePause), keyEquivalent: "p"
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        addAction("Export today as CSV…", #selector(exportToday), key: "e")
        addAction("Export date range as CSV…", #selector(exportRange), key: "E")
        addAction("Copy today's summary", #selector(copySummary), key: "c")
        addAction("Open data folder", #selector(openDataFolder), key: "")
        addAction("Edit settings…", #selector(openConfig), key: ",")

        menu.addItem(.separator())
        addAction("About TimeTrackBar…", #selector(showAbout), key: "")
        addAction("Quit TimeTrack", #selector(quit), key: "q")
    }

    private func addDisabled(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addAction(_ title: String, _ selector: Selector, key: String) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func togglePause() {
        if Recorder.isPaused { Recorder.resume() } else { Recorder.pause() }
        updateStatusTitle()
    }

    @objc private func openAccessibility() {
        Sampler.requestAccessibilityPermission()
        Sampler.openAccessibilitySettings()
    }

    @objc private func openDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.database])
    }

    @objc private func openConfig() {
        ConfigStore.createDefaultIfMissing()
        NSWorkspace.shared.open(Paths.configFile)
    }

    @objc private func copySummary() {
        let config = configStore.current
        guard let store,
              let bounds = DayKey.range(for: DayKey.today(dayStartHour: config.dayStartHour),
                                        dayStartHour: config.dayStartHour),
              let totals = try? store.appTotals(from: bounds.start, to: bounds.end)
        else { return }

        let total = totals.reduce(0) { $0 + $1.seconds }
        var lines = ["\(DayKey.today(dayStartHour: config.dayStartHour)) — \(formatDuration(total)) (\(decimalHours(total)) h)"]
        for row in totals where row.seconds >= 60 {
            lines.append("\(decimalHours(row.seconds)) h  \(row.app)")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    @objc private func exportToday() {
        let config = configStore.current
        let today = DayKey.today(dayStartHour: config.dayStartHour)
        guard let bounds = DayKey.range(for: today, dayStartHour: config.dayStartHour) else { return }
        exportSessionsCSV(from: bounds.start, to: bounds.end, suggestedName: "timetrack-\(today).csv")
    }

    @objc private func exportRange() {
        let config = configStore.current

        // Two date-only pickers in an alert: no custom window controller needed
        // for what is a twice-a-month operation.
        let fromPicker = AppDelegate.dayPicker()
        let toPicker = AppDelegate.dayPicker()
        fromPicker.dateValue = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
        toPicker.dateValue = Date()

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "From:"), fromPicker],
            [NSTextField(labelWithString: "To:"), toPicker],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 220, height: 56)

        let alert = NSAlert()
        alert.messageText = "Export date range"
        alert.informativeText = "Blocks of one minute or longer between the two days, inclusive."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Export…")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Swapped dates are an easy slip in two pickers — just fix the order.
        var (fromDate, toDate) = (fromPicker.dateValue, toPicker.dateValue)
        if fromDate > toDate { swap(&fromDate, &toDate) }

        let fromDay = DayKey.string(for: fromDate, dayStartHour: config.dayStartHour)
        let toDay = DayKey.string(for: toDate, dayStartHour: config.dayStartHour)
        guard let start = DayKey.range(for: fromDay, dayStartHour: config.dayStartHour),
              let end = DayKey.range(for: toDay, dayStartHour: config.dayStartHour)
        else { return }

        exportSessionsCSV(from: start.start, to: end.end,
                          suggestedName: "timetrack-\(fromDay)_to_\(toDay).csv")
    }

    private static func dayPicker() -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .yearMonthDay
        picker.sizeToFit()
        return picker
    }

    private func exportSessionsCSV(from: Date, to: Date, suggestedName: String) {
        guard let store, let sessions = try? store.sessions(from: from, to: to) else { return }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var lines = ["start,end,minutes,hours,app,title"]
        for s in sessions where s.seconds >= 60 {
            lines.append([
                stamp.string(from: s.start),
                stamp.string(from: s.end),
                String(s.seconds / 60),
                decimalHours(s.seconds),
                csvEscape(s.app),
                csvEscape(s.title),
            ].joined(separator: ","))
        }

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @objc private func showAbout() {
        AboutWindow.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    private func promptForAccessibility() {
        let alert = NSAlert()
        alert.messageText = "TimeTrack needs Accessibility permission"
        alert.informativeText = """
        Without it TimeTrack still records which app is in front, but window \
        titles stay blank — and the titles are what make a timesheet reconstructable.

        Open System Settings › Privacy & Security › Accessibility and enable TimeTrackBar.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Sampler.requestAccessibilityPermission()
            Sampler.openAccessibilitySettings()
        }
    }

    private func presentFatal(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "TimeTrack could not start"
        alert.informativeText = message
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }
}

private extension String {
    func padded(to width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }
}
