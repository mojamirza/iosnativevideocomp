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
    /// What the USER (or the target solve) actually asked for, before the
    /// source-rate ceiling clamped it — the UI uses the pair with
    /// `videoBitrate` to say "(capped)" honestly.
    var requestedVideoBitrate: Int = 0
    /// False when no bitrate (even the floor) can land under the target on
    /// this clip — the UI says so before any encode starts.
    var targetFeasible: Bool = true
    /// REAL HDR→SDR conversion requested (AVFoundation composition path
    /// in CompressionEngine). Only ever set
    /// when the source actually IS HDR — the engine branches on this
    /// (10-bit decode → CI tone-map → 8-bit 709 encode) and the verifier
    /// expects an 8-bit 709 output instead of a 10-bit HDR one.
    var sdrConvert: Bool = false
    /// USER ROTATION (degrees clockwise, applied in display space on top of
    /// the source's own transform). 0/90/180/270; 0 = keep native
    /// orientation. The encoded frame geometry is unchanged — rotation is a
    /// track-transform, not a pixel operation.
    var rotationDegrees: Int = 0
    /// TRIM window on the OUTPUT timeline (seconds). The engine bounds the
    /// whole read (video AND audio) to
    /// [startOffset + trimStart, startOffset + trimEnd]; nil = no trim.
    var trimStart: Double = 0
    var trimEnd: Double?
    /// USER-PICKED poster image (normalized JPEG, ≤1024px) from the setup
    /// Adjust section. The engine embeds it as QuickTime artwork metadata —
    /// Files/players show it as the video's icon — and the row thumbnail
    /// uses it directly. nil = automatic frame.
    var posterData: Data?

    var expectedFrames: Int {
        max(1, Int(duration * Double(fps > 0 ? fps : 30)))
    }

    var totalBitrate: Int { videoBitrate + audioBitrate }

    /// Whether the plan used FEWER bits than asked because the source caps
    /// the useful rate (bits beyond what the pixels encode just inflate the
    /// file). Displayed as "(capped)" everywhere a bitrate is shown.
    var bitrateCapped: Bool {
        requestedVideoBitrate > 0 && videoBitrate < requestedVideoBitrate
    }

    func estimatedSizeMB() -> Double {
        Double(estimatedBytes) / 1_000_000.0
    }

    /// EXACT expected output size in BYTES via SizeMath — the ONE formula.
    /// Includes audio AND the container-overhead the old estimates dropped.
    var estimatedBytes: Int64 {
        SizeMath.expectedBytes(videoBitrate: videoBitrate, audioBitrate: audioBitrate,
                               duration: duration)
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

        // Requested bitrate = what the user typed, clamped to the shared
        // SizeMath range (0.15–40 Mbps — matching Preset.bitrateRange so the
        // slider floor and the math agree).
        var requested = max(SizeMath.minVideoBitrate, Int(preset.fixedBitrateMbps * 1_000_000))
        // GUARANTEED TARGET (per video): when the preset carries a target
        // size, the BUDGET decides the video bitrate — solved through
        // SizeMath (the ONE formula: target − overhead, aimed at 95 %,
        // minus audio). Feasibility: even the floor bitrate must land under
        // the target, otherwise the UI says so before any encode starts.
        var feasible = true
        if let targetMB = preset.targetSizeMB {
            requested = SizeMath.videoBitrate(targetMB: targetMB,
                                              audioBitrate: audioBitrate,
                                              duration: duration)
            feasible = SizeMath.isFeasible(targetMB: targetMB,
                                           audioBitrate: audioBitrate,
                                           duration: duration)
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
            ? min(requested, max(SizeMath.minVideoBitrate, Int(min(ceiling, 40e9))))
            : requested
        // The CORRECTION pass in the coordinator solves PLAN-aware budgets —
        // remember here what the source ceiling threw away so the solver
        // never re-inflates into it.
        let capped = requested > videoBitrate
        let audioNote = probe.hasAudio
            ? String(format: "%.0f kbps audio", Double(audioBitrate) / 1000)
            : "no audio"
        let rationale: String
        if capped {
            rationale = String(
                format: "%.1f Mbps requested — capped to %@ Mbps for %d×%d (%.0f%% of source pixels, source is %.1f Mbps) · %@",
                Double(requested) / 1e6, SizeMath.mbpsLabel(videoBitrate),
                Int(outputSize.width), Int(outputSize.height),
                areaRatio * 100, probe.videoDataRate / 1e6,
                audioNote)
        } else {
            rationale = String(
                format: "%@ Mbps video · %@ at %d×%d",
                SizeMath.mbpsLabel(requested), audioNote,
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
            audioChannels: preset.audioChannels,
            requestedVideoBitrate: requested,
            targetFeasible: feasible,
            sdrConvert: preset.hdrToSDR == true && probe.tags.isHDR
        )
    }

    static func evenSize(_ s: CGSize) -> CGSize {
        CGSize(width: max(2, Int(s.width) - Int(s.width) % 2),
               height: max(2, Int(s.height) - Int(s.height) % 2))
    }
}
