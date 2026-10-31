import Foundation

/// The sampling loop: takes a sample every `intervalSeconds` and writes it to
/// the store. Used by both `timetrack run` and the menu bar app, so exactly one
/// of them may hold the lock at a time.
public final class Recorder {
    public enum StartResult {
        case started
        case alreadyRunning(pid: Int32)
        case missingPermission
    }

    private let store: Store
    private let configStore: ConfigStore
    private var timer: DispatchSourceTimer?
    private var lockFD: Int32 = -1
    private var currentInterval: Int = 0

    /// Called after each successful write, so a UI can refresh itself.
    public var onSample: ((Sample) -> Void)?
    /// Called with a human-readable message when something goes wrong.
    public var onError: ((String) -> Void)?

    public private(set) var isRunning = false

    public init(store: Store, configStore: ConfigStore = ConfigStore()) {
        self.store = store
        self.configStore = configStore
    }

    // MARK: - Pause flag

    public static var isPaused: Bool {
        FileManager.default.fileExists(atPath: Paths.pauseFlag.path)
    }

    public static func pause() {
        FileManager.default.createFile(atPath: Paths.pauseFlag.path, contents: Data())
    }

    public static func resume() {
        try? FileManager.default.removeItem(at: Paths.pauseFlag)
    }

    // MARK: - Single-instance lock

    /// PID of the process currently sampling, if any.
    public static func runningPID() -> Int32? {
        let fd = open(Paths.lockFile.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // If we can take the lock, nobody else holds it.
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        guard let text = try? String(contentsOf: Paths.lockFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return -1 }
        return pid
    }

    private func acquireLock() -> Bool {
        lockFD = open(Paths.lockFile.path, O_CREAT | O_RDWR, 0o644)
        guard lockFD >= 0 else { return false }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD)
            lockFD = -1
            return false
        }
        ftruncate(lockFD, 0)
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = pid.withCString { write(lockFD, $0, strlen($0)) }
        return true
    }

    private func releaseLock() {
        guard lockFD >= 0 else { return }
        flock(lockFD, LOCK_UN)
        close(lockFD)
        lockFD = -1
        try? FileManager.default.removeItem(at: Paths.lockFile)
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start(requirePermission: Bool = true) -> StartResult {
        if requirePermission && !Sampler.hasAccessibilityPermission() {
            return .missingPermission
        }
        guard acquireLock() else {
            return .alreadyRunning(pid: Recorder.runningPID() ?? -1)
        }
        isRunning = true
        scheduleTimer(interval: configStore.current.intervalSeconds)
        return .started
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
        releaseLock()
    }

    private func scheduleTimer(interval: Int) {
        timer?.cancel()
        currentInterval = interval
        // NSWorkspace and the Accessibility API expect the main thread, and the
        // main run loop is alive in both hosts (CLI and menu bar app).
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        // A little leeway lets the system coalesce our wakeups — easier on the battery.
        t.schedule(deadline: .now() + .seconds(interval),
                   repeating: .seconds(interval),
                   leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let config = configStore.current

        // Picking up an interval change without a restart.
        if config.intervalSeconds != currentInterval {
            scheduleTimer(interval: config.intervalSeconds)
            return
        }
        guard !Recorder.isPaused else { return }
        guard let sample = Sampler.sample(config: config) else { return }

        do {
            try store.insert(sample)
            onSample?(sample)
        } catch {
            onError?("\(error)")
        }
    }
}
