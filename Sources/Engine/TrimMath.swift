import Foundation

/// Pure trim-window math shared by the setup flow (planning, estimates, the
/// before/after story) and the queue coordinator's resume path (re-planning
/// a persisted record) — one definition so they can never disagree.
///
/// "Trimmed" = a window ≥ 0.5 s that cuts REAL content off either side
/// (the 0.05 s epsilon absorbs float noise at the extremes; an end-only
/// cut MUST count, which is exactly the bug this logic first fixed — the
/// old start() compared `trimEnd` against `trimEnd - trimStart`).
enum TrimMath {
    static func isTrimmed(start: Double, end: Double, duration: Double) -> Bool {
        end - start >= 0.5 && (start > 0.05 || end < duration - 0.05)
    }

    /// The probe as the trim window sees it: `duration` becomes the window
    /// length and `fileSize` scales proportionally, so the −X% story, the
    /// target-size solve and the report's input bytes all describe the
    /// TRIMMED video, never the full source.
    static func apply(_ probe: ProbeResult, start: Double, end: Double) -> ProbeResult {
        guard isTrimmed(start: start, end: end, duration: probe.duration) else { return probe }
        var q = probe
        q.duration = end - start
        q.fileSize = Int64(Double(probe.fileSize) * q.duration / max(probe.duration, 0.1))
        return q
    }
}
