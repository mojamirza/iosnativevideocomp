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

    var expectedFrames: Int {
        max(1, Int(duration * Double(fps > 0 ? fps : 30)))
    }

    var totalBitrate: Int { videoBitrate + audioBitrate }

    func estimatedSizeMB() -> Double {
        Double(totalBitrate) / 8.0 * duration / 1_000_000.0
    }
}

/// Turns a preset + probed source into a concrete encoder plan. Deliberately
/// simple and predictable: the preset's exact bitrate and resolution are used
/// as-is, so the estimate always scales with the chosen preset.
enum QualitySizeOptimizer {

    static func plan(preset: Preset, probe: ProbeResult) -> OptimizerPlan {
        let outputSize = preset.resolution.outputSize(for: probe.sourceSize)
        let duration = max(0.1, probe.duration)
        let fps = probe.nominalFPS > 0 ? probe.nominalFPS : 30
        let audioBitrate = max(32, min(preset.audioBitrateKbps, 320)) * 1000

        // Exact bitrate from the preset, with a tiny floor for degenerate input.
        let requested = max(200_000, Int(preset.fixedBitrateMbps * 1_000_000))
        // Cap at the source's own rate: re-encoding above it only grows the
        // file without adding detail. (Applied to the encode too, so the
        // estimate and the actual output always agree.)
        let sourceMax = probe.videoDataRate > 0 ? probe.videoDataRate * 0.95 : Double.infinity
        let videoBitrate = min(requested, max(200_000, Int(sourceMax)))
        let rationale: String
        if Double(requested) > sourceMax {
            rationale = String(
                format: "%.1f Mbps requested — source is %.1f Mbps, capped so the output never grows · %.0f kbps audio at %d×%d",
                Double(requested) / 1e6, probe.videoDataRate / 1e6,
                Double(audioBitrate) / 1000,
                Int(outputSize.width), Int(outputSize.height))
        } else {
            rationale = String(
                format: "%.1f Mbps video · %.0f kbps audio at %d×%d",
                preset.fixedBitrateMbps, Double(audioBitrate) / 1000,
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
            source: probe
        )
    }

    static func evenSize(_ s: CGSize) -> CGSize {
        CGSize(width: max(2, Int(s.width) - Int(s.width) % 2),
               height: max(2, Int(s.height) - Int(s.height) % 2))
    }
}
