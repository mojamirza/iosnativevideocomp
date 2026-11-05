import Foundation

/// Wall-clock race helper: runs an async operation against a hard time limit.
/// On timeout the loser task is *abandoned* (unstructured, never awaited), so a
/// stuck operation can delay at most `seconds` — it can never wedge the caller.
enum AsyncTimeout {

    private final class OnceClaim: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        var isFired: Bool {
            lock.lock(); defer { lock.unlock() }; return fired
        }
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    static func run<T: Sendable>(
        seconds: Double, _ op: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let once = OnceClaim()
            Task.detached {
                let v = await op()
                if once.claim() { cont.resume(returning: v) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
                // Grace: the app may have JUST resumed from suspension — the
                // operation often finishes within seconds of resume. Without
                // this window, resuming mid-operation would execute a healthy
                // encode (the wall-clock deadline expired while suspended).
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if once.claim() { cont.resume(returning: nil) }
            }
        }
    }

    /// Stall-based watchdog: the deadline RE-ARMS on every heartbeat, so it
    /// fires only when work has genuinely stopped making progress — never
    /// merely because the app was suspended and resumed.
    static func runWithHeartbeat<T: Sendable>(
        watchdog: StallWatchdog,
        stallSeconds: Double,
        minimumWallClock: Double,
        _ op: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let once = OnceClaim()
            Task.detached {
                let v = await op()
                if once.claim() { cont.resume(returning: v) }
            }
            Task.detached {
                // MONOTONIC timing: Date() jumps on NTP syncs and timezone
                // changes — a forward jump could fire the deadline early, a
                // backward one could mask it. systemUptime is monotonic.
                let start = ProcessInfo.processInfo.systemUptime
                while !once.isFired {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if once.isFired { return }
                    guard ProcessInfo.processInfo.systemUptime - start >= minimumWallClock else { continue }
                    if watchdog.stalled(seconds: stallSeconds) {
                        // Grace: an app that just resumed from suspension can
                        // beat a moment late — require the stall to persist.
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        if once.isFired { return }
                        if watchdog.stalled(seconds: stallSeconds), once.claim() {
                            cont.resume(returning: nil)
                        }
                        return
                    }
                }
            }
        }
    }
}

/// Progress heartbeat source for stall watchdogs. Thread-safe.
/// Timing is MONOTONIC (ProcessInfo.systemUptime), never Date(): wall-clock
/// jumps (NTP, timezone) could fire a stall early or mask one, and a device
/// sleep must not be misread as a stalled encode — systemUptime freezes
/// while the device sleeps.
final class StallWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBeat = ProcessInfo.processInfo.systemUptime

    func beat() {
        lock.lock(); lastBeat = ProcessInfo.processInfo.systemUptime; lock.unlock()
    }

    /// True when no beat has arrived for `seconds`.
    func stalled(seconds: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastBeat >= seconds
    }
}
