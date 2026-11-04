import Foundation

/// THE single source of truth for every target-size / bitrate / expected-
/// bytes conversion. The editor, the planner, the coordinator's measured
/// re-encode and the verifier all call these — one formula, one set of
/// constants. The previous state had three independent fits: the editor
/// solved 0.92·(target − audio), the planner solved 0.95·(0.98·target −
/// audio), and the coordinator aimed the correction pass at 100 % of the
/// budget — three different answers to one question.
enum SizeMath {

    /// Sane encoder floor/ceiling in bits per second (0.15–40 Mbps, matching
    /// `Preset.bitrateRange` so the slider floor and the math agree).
    static let minVideoBitrate = 150_000
    static let maxVideoBitrate = 40_000_000

    /// Fraction of (target − container overhead) the FIRST pass aims at:
    /// VideoToolbox's average-bitrate mode drifts high on hard content, so
    /// aiming at the full budget guarantees a lucky overshoot.
    static let firstPassFill = 0.95
    /// The CORRECTION pass aims lower: it only ever runs after a measured
    /// overshoot, so the re-encode needs extra slack to close cleanly
    /// without a third pass.
    static let correctionFill = 0.92

    /// Container (mux + index + track metadata) overhead. Never below a
    /// floor — tiny files are mostly overhead and the relative share must
    /// not vanish to zero.
    static func containerOverhead(forBytes bytes: Double) -> Double {
        max(64_000, bytes * 0.015)
    }

    /// Fixed VIDEO bitrate that lands video + audio + overhead at or under
    /// `targetMB`, aimed at `fill` of the payload budget. Audio that
    /// doesn't exist is never budgeted (the caller passes 0).
    static func videoBitrate(targetMB: Double, audioBitrate: Int,
                             duration: Double, fill: Double = firstPassFill) -> Int {
        guard duration > 0 else { return minVideoBitrate }
        let total = targetMB * 1_000_000
        let audio = Double(audioBitrate) / 8 * duration
        let video = (total - containerOverhead(forBytes: total)) * fill - audio
        let bps = video * 8 / duration
        guard bps.isFinite else { return minVideoBitrate }
        return Int(min(Double(maxVideoBitrate), max(Double(minVideoBitrate), bps)))
    }

    /// Honest expected file size: payload (video + audio, each bits/s ÷ 8 ×
    /// duration) PLUS the container overhead the old estimates silently
    /// dropped (a "100 MB" target showed "≈ 93 MB" — the overhead is real
    /// and must be counted in the UI too).
    static func expectedBytes(videoBitrate: Int, audioBitrate: Int, duration: Double) -> Int64 {
        let payload = Double(videoBitrate + audioBitrate) / 8 * duration
        return Int64(payload + containerOverhead(forBytes: payload))
    }

    /// Can ANY bitrate hit the target on this clip? The min rate × duration
    /// plus audio plus overhead must still fit — a 1 MB target on an hour
    /// of video simply can't be honored.
    static func isFeasible(targetMB: Double, audioBitrate: Int, duration: Double) -> Bool {
        Double(expectedBytes(videoBitrate: minVideoBitrate, audioBitrate: audioBitrate,
                             duration: duration)) <= targetMB * 1_000_000
    }

    /// Readout label shared by the editor, the preset rows and the estimate
    /// bar: two decimals under 10 Mbps so what the user TYPED (the editor
    /// accepts full precision) matches what is SHOWN.
    static func mbpsLabel(_ bps: Int) -> String {
        let m = Double(bps) / 1e6
        return m < 10 ? String(format: "%.2f", m) : String(format: "%.1f", m)
    }
}
