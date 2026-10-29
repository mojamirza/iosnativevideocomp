import AVFoundation

/// Everything the encoder needs, decided once per job by the **Quality-Size Optimizer**.
struct OptimizerPlan: Hashable {
    var outputSize: CGSize
    var videoBitrate: Int           // bits/s
    var audioBitrate: Int           // bits/s
    var fps: Float                  // nominal fps for encoder metadata
    var fpsCap: Int?
    var scaleNeeded: Bool
    var isHDR: Bool
    var sourceBitDepth: Int
    var complexity: ComplexityScore
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

/// The second pillar of the product: instead of a dumb constant bitrate,
/// the optimizer combines
///   1. the goal (smallest / balanced / best, fixed Mbps, or exact MB size target),
///   2. per-frame complexity measured with Core Image,
///   3. the effective output geometry,
///   4. and never allocates more than the source bitrate (never a bigger file for nothing).
enum QualitySizeOptimizer {

    static func plan(preset: Preset, probe: ProbeResult, complexity: ComplexityScore) -> OptimizerPlan {
        let outputSize = preset.resolution.outputSize(for: probe.sourceSize)
        let duration = max(0.1, probe.duration)
        let fps = probe.nominalFPS > 0 ? probe.nominalFPS : 30
        let audioBitrate = max(32, min(preset.audioBitrateKbps, 320)) * 1000

        var videoBitrate = 0
        var rationale = ""

        let area = Double(outputSize.width * outputSize.height)
        let pixelsPerSecond = area * Double(fps)
        let sourceMax = probe.videoDataRate > 0 ? probe.videoDataRate * 0.95 : Double.infinity
        let floor_ = max(500_000.0, area * 0.0006)
        let complexityFactor = 0.62 + 0.75 * complexity.value   // 0.62 ... 1.37
        let codecFactor: Double = preset.codec == .h264 ? 1.55 : 1.0

        if let sizeTargetMB = preset.sizeTargetMB, sizeTargetMB > 0 {
            // Size-target mode: (target bytes -> total bits) minus audio budget.
            let totalBits = sizeTargetMB * 8_000_000.0
            let audioBits = Double(audioBitrate) * 1000.0 * duration
            let videoBits = max(0.0, totalBits - audioBits)
            let planned = Int(videoBits / duration)
            videoBitrate = clamp(planned, floor_, sourceMax)
            rationale = String(
                format: "Size target ≈ %.0f MB → %.1f Mbps video · %.0f kbps audio",
                sizeTargetMB, Double(videoBitrate) / 1_000_000, Double(audioBitrate) / 1000)
        } else if let fixed = preset.fixedBitrateMbps, fixed > 0 {
            videoBitrate = clamp(Int(fixed * 1_000_000), floor_, sourceMax)
            if Int(fixed * 1_000_000) > Int(sourceMax) {
                rationale = String(format: "Fixed %.1f Mbps (capped to source %.1f Mbps — higher would only pad the file)",
                                   fixed, sourceMax / 1_000_000)
            } else {
                rationale = String(format: "Fixed %.1f Mbps (%.0f kbps audio)", fixed, Double(audioBitrate) / 1000)
            }
        } else {
            // Adaptive: bits-per-pixel tuned by quality goal, scaled by measured complexity.
            let bpp: Double
            switch preset.autoQuality ?? .balanced {
            case .smallest: bpp = 0.034
            case .balanced: bpp = 0.055
            case .best:     bpp = 0.092
            }
            let raw = pixelsPerSecond * bpp * codecFactor * complexityFactor
            videoBitrate = clamp(Int(raw), floor_, sourceMax)
            rationale = String(
                format: "Adaptive %@ · complexity %.2f (%d frames analysed) → %.1f Mbps at %d×%d",
                (preset.autoQuality ?? .balanced).label,
                complexity.value, complexity.sampledFrames,
                Double(videoBitrate) / 1_000_000,
                Int(outputSize.width), Int(outputSize.height))
        }

        let scaleNeeded = abs(outputSize.width - probe.sourceSize.width) > 1 ||
                          abs(outputSize.height - probe.sourceSize.height) > 1
        let isHDR = probe.tags.isHDR

        // Scaled paths are bit-depth & rotation aware (see CompressionEngine):
        // 10-bit/HDR sources scale through VideoToolbox's pixel transfer — a
        // pure geometric rescale, no tonemapping, tags preserved. Rotated
        // sources scale with transposed encode dimensions so the preferred-
        // transform stays consistent. Nothing needs to be given up here.
        return OptimizerPlan(
            outputSize: outputSize,
            videoBitrate: videoBitrate,
            audioBitrate: audioBitrate,
            fps: fps,
            fpsCap: preset.fpsCap,
            scaleNeeded: scaleNeeded,
            isHDR: isHDR,
            sourceBitDepth: probe.bitDepth,
            complexity: complexity,
            rationale: rationale,
            duration: duration,
            source: probe
        )
    }

    static func clamp(_ v: Int, _ lo: Double, _ hi: Double) -> Int {
        Int(max(lo, min(v > 0 ? Double(v) : 0, hi)))
    }

    static func evenSize(_ s: CGSize) -> CGSize {
        CGSize(width: max(2, Int(s.width) - Int(s.width) % 2),
               height: max(2, Int(s.height) - Int(s.height) % 2))
    }
}
