import Foundation

/// Tracks every process spawned for health checks so none can outlive the app.
/// `killAll()` runs from `applicationWillTerminate` and from an `atexit` hook,
/// covering both normal quits and mid-check exits. Lock-based (not an actor)
/// so it stays callable from those synchronous shutdown paths.
public final class ProcessRegistry: @unchecked Sendable {
    public static let shared = ProcessRegistry()

    private let lock = NSLock()
    private var pids: Set<pid_t> = []

    private init() {
        atexit { ProcessRegistry.shared.killAll() }
    }

    func register(_ pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        pids.insert(pid)
    }

    func unregister(_ pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        pids.remove(pid)
    }

    public var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pids.count
    }

    public func killAll() {
        lock.lock()
        let snapshot = pids
        pids.removeAll()
        lock.unlock()
        for pid in snapshot {
            ProcessRegistry.killTree(pid, signal: SIGKILL)
        }
    }

    /// Signals the process group when there is one (catches children that
    /// `npx`/`uvx` fork), falling back to the single process.
    static func killTree(_ pid: pid_t, signal: Int32) {
        if kill(-pid, signal) != 0 {
            kill(pid, signal)
        }
    }
}
