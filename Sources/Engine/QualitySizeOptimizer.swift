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
        let videoBitrate = min(requested, max(200_000, Int(ceiling)))
        let rationale: String
        if Double(requested) > ceiling {
            rationale = String(
                format: "%.1f Mbps requested — capped to %.1f Mbps for %d×%d (%.0f%% of source pixels, source is %.1f Mbps) · %.0f kbps audio",
                Double(requested) / 1e6, Double(videoBitrate) / 1e6,
                Int(outputSize.width), Int(outputSize.height),
                areaRatio * 100, probe.videoDataRate / 1e6,
                Double(audioBitrate) / 1000)
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
