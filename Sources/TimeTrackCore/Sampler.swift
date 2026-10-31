import AppKit
import ApplicationServices
import Foundation

/// Reads what is in front of the user right now.
public enum Sampler {

    // MARK: - Accessibility permission

    /// Window titles come from the Accessibility API, which macOS gates behind
    /// System Settings › Privacy & Security › Accessibility.
    public static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Same check, but macOS shows the "open System Settings" prompt if not granted.
    @discardableResult
    public static func requestAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Idle detection

    /// Seconds since the last keyboard or mouse input.
    public static func idleSeconds() -> Double {
        let types: [CGEventType] = [
            .keyDown, .flagsChanged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .scrollWheel,
        ]
        let values = types.map {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }
        return values.min() ?? 0
    }

    /// True while the screen is locked or the session is switched away — we do
    /// not want to log the login window as "work".
    public static func screenIsLocked() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = info["CGSSessionScreenIsLocked"] as? Int, locked == 1 { return true }
        if let onConsole = info["kCGSSessionOnConsoleKey"] as? Int, onConsole == 0 { return true }
        return false
    }

    // MARK: - Front window

    /// The frontmost app and, when permitted, its focused window title.
    /// Returns nil when the app is on the ignore list or nothing is frontmost.
    public static func sample(config: Config) -> Sample? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let name = front.localizedName ?? front.bundleIdentifier ?? "Unknown"
        let bundleId = front.bundleIdentifier ?? ""

        if config.isIgnored(name: name, bundleId: bundleId) { return nil }

        let idle = screenIsLocked()
            || (config.idleThresholdSeconds > 0
                && idleSeconds() >= Double(config.idleThresholdSeconds))

        var title = ""
        if config.recordTitles && !config.isPrivate(name: name, bundleId: bundleId) {
            title = config.clean(title: focusedWindowTitle(pid: front.processIdentifier) ?? "")
        }

        return Sample(
            ts: Date(),
            day: DayKey.string(for: Date(), dayStartHour: config.dayStartHour),
            app: name,
            bundleId: bundleId,
            title: title,
            idle: idle,
            intervalSeconds: config.intervalSeconds
        )
    }

    /// Title of the focused window of a process, via the Accessibility API.
    public static func focusedWindowTitle(pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        // An unresponsive app must not stall the sampling loop.
        AXUIElementSetMessagingTimeout(axApp, 1.0)

        var windowRef: CFTypeRef?
        var err = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef)
        if err != .success || windowRef == nil {
            err = AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &windowRef)
        }
        guard err == .success, let ref = windowRef, CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            return nil
        }
        let window = ref as! AXUIElement

        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return title
    }
}
