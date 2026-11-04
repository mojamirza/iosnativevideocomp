import AVFoundation

/// Everything the encoder needs, decided once per job from the preset.
struct OptimizerPlan: Hashable {
    var outputSize: CGSize
    var videoBitrate: Int           // bits/s
    var audioBitrate: Int           // bits/s
    var fps: Float                  // nominal fps for encoder metadata
    var fpsCap: Int?
    var scaleNeeded: Bool
    var isHDR: Bool
    var sourceBitDepth: Int
    var rationale: String
    var duration: Double
    var source: ProbeResult
    /// Guaranteed target size (MB). nil on plain fixed-bitrate plans.
    var targetSizeMB: Double?
    /// Forced AAC channel count (1 = mono lecture audio). nil = source's own.
    var audioChannels: Int?

    var expectedFrames: Int {
        max(1, Int(duration * Double(fps > 0 ? fps : 30)))
    }

    var totalBitrate: Int { videoBitrate + audioBitrate }

    func estimatedSizeMB() -> Double {
        Double(totalBitrate) / 8.0 * duration / 1_000_000.0
    }

    /// EXACT estimated output size in BYTES, computed once from the bitrate
    /// math (bits/s ÷ 8 × s). The UI previously went through
    /// `estimatedSizeMB()` — which returns DECIMAL megabytes — and then
    /// multiplied by 1_048_576, inflating every estimate by ≈4.9 %.
    var estimatedBytes: Int64 {
        Int64(Double(totalBitrate) / 8.0 * duration)
    }

    /// The guaranteed-fit budget in bytes (nil on fixed-bitrate plans).
    var targetBytes: Int64? {
        targetSizeMB.map { Int64($0 * 1_000_000.0) }
    }

    /// Audio's share of the estimated file (guaranteed-fit budgeting).
    var audioBytes: Int64 {
        Int64(Double(audioBitrate) / 8.0 * duration)
    }
}

/// Turns a preset + probed source into a concrete encoder plan. Deliberately
/// simple and predictable: the preset's exact bitrate and resolution are used
/// as-is, so the estimate always scales with the chosen preset.
enum QualitySizeOptimizer {

    static func plan(preset: Preset, probe: ProbeResult) -> OptimizerPlan {
        let outputSize = preset.resolution.outputSize(for: probe.sourceSize)
        let duration = max(0.1, probe.duration)
        let rawFPS = probe.nominalFPS > 0 ? probe.nominalFPS : 30
        // The plan's fps must reflect the CAP, not the raw source rate:
        // encoder GOP metadata, expected-frame counts and the live ETA are
        // all derived from plan.fps.
        let fps: Float
        if let cap = preset.fpsCap {
            fps = min(rawFPS, Float(cap))
        } else {
            fps = rawFPS
        }
        // Silent sources plan NO audio — the size estimate must not count a
        // track that doesn't exist (and the report must not describe one).
        let audioBitrate = probe.hasAudio
            ? max(32, min(preset.audioBitrateKbps, 320)) * 1000
            : 0

        // Exact bitrate from the preset, with a tiny floor for degenerate input.
        var requested = max(200_000, Int(preset.fixedBitrateMbps * 1_000_000))
        // GUARANTEED TARGET (per video): when the preset carries a target
        // size, the BUDGET decides the video bitrate — not the preset's own
        // fixed value. (videoBudget = total target − audio − ~2% container
        // overhead; solving at 95% of it leaves the overshoot to the
        // coordinator's check + one measured re-encode.)
        if let targetMB = preset.targetSizeMB {
            let audioBytes = Double(audioBitrate) / 8.0 * duration
            let overhead = max(64_000.0, Double(targetMB) * 1_000_000.0 * 0.02)
            let videoBudget = Double(targetMB) * 1_000_000.0 - audioBytes - overhead
            requested = max(200_000, min(40_000_000,
                                         Int(videoBudget * 8.0 * 0.95 / duration)))
        }
        // Ceiling: bits beyond what the pixels can use only grow the file.
        // When DOWNSCALING, scale the source's own rate by the pixel-area
        // ratio (with modest headroom) so lower resolutions always plan
        // fewer bits — 480p < 720p < 1080p, even for low-bitrate sources.
        // Keeping resolution caps at ~95% of the source (no free detail).
        let srcArea = max(1.0, Double(probe.sourceSize.width) * Double(probe.sourceSize.height))
        let outArea = Double(outputSize.width) * Double(outputSize.height)
        let areaRatio = min(1.0, outArea / srcArea)
        let ceiling: Double = probe.videoDataRate > 0
            ? probe.videoDataRate * areaRatio * (areaRatio < 1 ? 1.25 : 0.95)
            : .infinity
        // Int(Double) TRAPS when the value isn't representable — and an
        // unknown source data rate leaves ceiling at INFINITY (the old
        // Int(ceiling) crashed the setup sheet for such files). Apply the
        // ceiling only when finite, hard-clamped well inside Int range;
        // unknown rates skip it entirely (pure fixed-bitrate).
        let videoBitrate: Int = ceiling.isFinite
            ? min(requested, max(200_000, Int(min(ceiling, 40e9))))
            : requested
        let audioNote = probe.hasAudio
            ? String(format: "%.0f kbps audio", Double(audioBitrate) / 1000)
            : "no audio"
        let rationale: String
        if videoBitrate < requested {
            rationale = String(
                format: "%.1f Mbps requested — capped to %.1f Mbps for %d×%d (%.0f%% of source pixels, source is %.1f Mbps) · %@",
                Double(requested) / 1e6, Double(videoBitrate) / 1e6,
                Int(outputSize.width), Int(outputSize.height),
                areaRatio * 100, probe.videoDataRate / 1e6,
                audioNote)
        } else {
            rationale = String(
                format: "%.1f Mbps video · %@ at %d×%d",
                preset.fixedBitrateMbps, audioNote,
                Int(outputSize.width), Int(outputSize.height))
        }

        let scaleNeeded = abs(outputSize.width - probe.sourceSize.width) > 1 ||
                          abs(outputSize.height - probe.sourceSize.height) > 1

        // Scaled paths are bit-depth & rotation aware (see CompressionEngine):
        // 10-bit/HDR sources scale through VideoToolbox's pixel transfer — a
        // pure geometric rescale, no tonemapping, tags preserved. Rotated
        // sources scale with transposed encode dimensions so the preferred-
        // transform stays consistent.
        return OptimizerPlan(
            outputSize: outputSize,
            videoBitrate: videoBitrate,
            audioBitrate: audioBitrate,
            fps: fps,
            fpsCap: preset.fpsCap,
            scaleNeeded: scaleNeeded,
            isHDR: probe.tags.isHDR,
            sourceBitDepth: probe.bitDepth,
            rationale: rationale,
            duration: duration,
            source: probe,
            targetSizeMB: preset.targetSizeMB,
            audioChannels: preset.audioChannels
        )
    }

    static func evenSize(_ s: CGSize) -> CGSize {
        CGSize(width: max(2, Int(s.width) - Int(s.width) % 2),
               height: max(2, Int(s.height) - Int(s.height) % 2))
    }
}
