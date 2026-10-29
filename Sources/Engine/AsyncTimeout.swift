import Foundation

/// Wall-clock race helper: runs an async operation against a hard time limit.
/// On timeout the loser task is *abandoned* (unstructured, never awaited), so a
/// stuck operation can delay at most `seconds` — it can never wedge the caller.
enum AsyncTimeout {

    private final class OnceClaim: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
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
                if once.claim() { cont.resume(returning: nil) }
            }
        }
    }
}
