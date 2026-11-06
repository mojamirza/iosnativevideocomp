import AVFoundation
import VideoToolbox

/// Cooperative cancellation + error signalling shared between the UI and the
/// encoder thread(s).
///
/// `cancel()` (user) and `fail(_:)` (engine error) both run every registered
/// hook, but each holds the reason so the caller can distinguish them: the
/// engine checks `error` FIRST, then `cancelled`.
final class EngineFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var _error: Error?
    private var _hooks: [() -> Void] = []

    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return _error }

    /// Registered by the engine's pipes: on cancel()/fail() every hook runs —
    /// they stop the reader and resume the pipe continuations THROUGH THE
    /// PIPE'S OWN SERIAL QUEUE, so any in-flight block finishes first and no
    /// resume can race an append.
    func addCancelHook(_ hook: @escaping () -> Void) {
        lock.lock()
        let alreadyDone = _cancelled
        if !alreadyDone { _hooks.append(hook) }
        lock.unlock()
        if alreadyDone { hook() }   // cancel happened first — run now
    }

    /// User cancel: records the state and drains the hooks.
    func cancel() {
        lock.lock()
        _cancelled = true
        let hooks = _hooks
        _hooks = []
        lock.unlock()
        for h in hooks { h() }
    }

    /// Engine-side failure (decode/append/transfer errors): records the FIRST
    /// error and runs the cancel hooks so BOTH pipes wake up immediately —
    /// without this, a failed video pipe would leave the audio pipe waiting
    /// for a callback that never comes (surfacing only via the watchdog).
    func fail(_ e: Error) {
        lock.lock()
        if _error == nil { _error = e }
        _cancelled = true
        let hooks = _hooks
        _hooks = []
        lock.unlock()
        for h in hooks { h() }
    }
}

/// The fps-cap slot grid, extracted from the video pipe so the cadence math
/// is unit-testable: the first accepted frame opens a slot one period wide;
/// frames inside the open slot are dropped (a quarter-period tolerance
/// absorbs timestamp jitter just above the cap); lag beyond a full period
/// re-anchors the grid so VFR bursts stay capped.
struct FrameCapper {
    let cap: Int
    private var nextSlot = CMTime.zero
    private var slotActive = false

    init(cap: Int) {
        self.cap = cap
    }

    mutating func shouldKeep(_ pts: CMTime) -> Bool {
        let period = CMTime(value: 1, timescale: CMTimeScale(cap))
        let tol = CMTime(value: 1, timescale: CMTimeScale(cap * 4))
        if !slotActive {
            slotActive = true
            nextSlot = CMTimeAdd(pts, period)
            return true
        }
        if CMTimeCompare(pts, CMTimeSubtract(nextSlot, tol)) < 0 {
            // Still inside the open slot (tolerance edge included) — drop.
            return false
        }
        if CMTimeGetSeconds(CMTimeSubtract(pts, nextSlot)) > 2.0 / Double(cap) {
            // Grid lagged more than a full period: re-anchor HERE.
            nextSlot = CMTimeAdd(pts, period)
            return true
        }
        nextSlot = CMTimeAdd(nextSlot, period)
        return true
    }
}

enum CompressionError: LocalizedError {
    case noVideoTrack
    case readerFailed(String)
    case writerFailed(String)
    case cancelled
    case framesDropped(Int)
    /// The writer refused to start while metadata items were set — the
    /// compress() wrapper catches this, flips PrivacyScrub.sessionDisabled
    /// and retries once with an empty metadata list.
    case metadataRejected(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The selected file has no video track."
        case .readerFailed(let m): return "Decode failed: \(m)"
        case .writerFailed(let m): return "Encode failed: \(m)"
        case .cancelled: return "Compression was cancelled."
        case .framesDropped(let n):
            return "Buffer starvation while encoding — \(n) frames could not be allocated or transferred, so the output would stutter."
        case .metadataRejected(let m):
            return "The writer refused the output's metadata: \(m)"
        }
    }
}

/// The pipeline: AVAssetReader → VTPixelTransfer (only when scaling) →
/// VideoToolbox (through AVAssetWriter).
///
/// Paths, all strictly color-safe:
///  * Direct path        — "keep resolution": decoded pixel buffers
///                         (bit-depth aware: 10-bit buffers for 10-bit/HDR
///                         sources) go straight into the encoder with the
///                         source color tags intact.
///  * VTPixelTransfer    — any downscale (8-bit and 10-bit alike) through a
///                         VideoToolbox pixel transfer session (normal
///                         scaling + averaging downsampling, the documented
///                         anti-aliasing switch). Pure geometric rescale:
///                         no tonemapping, no bit-depth loss, source color
///                         metadata re-applied on the destination buffer
///                         BEFORE transferring.
///
/// IMPORTANT: the reader always DECODES (explicit pixel format settings). Passing
/// compressed samples into an input configured for re-encoding is invalid.

enum CompressionEngine {

    private final class ResumeBox {
        private let lock = NSLock()
        private var done = false
        private let continuation: CheckedContinuation<Void, Never>
        init(_ c: CheckedContinuation<Void, Never>) { continuation = c }
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
        func resumeOnce() {
            lock.lock()
            defer { lock.unlock() }
            if !done {
                done = true
                continuation.resume()
            }
        }
    }

    /// One pixel-transfer session for ANY downscale (8-bit SDR included).
    /// The DOCUMENTED scaling modes are Normal / CropSourceToCleanAperture /
    /// Letterbox / Trim — the old "HighQuality" value is not a scaling mode
    /// at all, and the ignored OSStatus made the failure invisible (the
    /// session silently kept its default). "Normal" is set explicitly and
    /// the status is checked; aliasing on big downscale ratios is handled by
    /// the AVERAGING downsampling mode instead (that's the dedicated switch
    /// for 4K→720p: average the source block instead of point-decimating).
    private static func makeTransferSession() -> VTPixelTransferSession? {
        var s: VTPixelTransferSession?
        // VTCreatePixelTransferSession is macOS-only; iOS uses the classic call.
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                           pixelTransferSessionOut: &s) == noErr, let s else {
            return nil
        }
        let modeStatus = VTSessionSetProperty(
            s,
            key: kVTPixelTransferPropertyKey_ScalingMode,
            value: "Normal" as CFString)
        if modeStatus != noErr {
            NSLog("VidCompress: explicit scaling mode rejected (%d) — using VT default", modeStatus)
        }
        // Anti-aliasing: averaging downsampling for every downscale. The
        // VALUE constants (single macros like the scaling-mode ones) are not
        // exported to Swift; the property's documented value is "Average".
        let dsStatus = VTSessionSetProperty(
            s,
            key: kVTPixelTransferPropertyKey_DownsamplingMode,
            value: "Average" as CFString)
        if dsStatus != noErr {
            NSLog("VidCompress: averaging downsampling rejected (%d) — using VT default", dsStatus)
        }
        return s
    }

    /// Returns the AUDIO bitrate actually applied (bits/s; 0 when the output
    /// ships without audio): the canApply ladder may step DOWN from the
    /// plan's request, and the coordinator writes the returned value into
    /// the plan so the verifier's report describes the real file.
    static func compress(source: URL,
                         output: URL,
                         preset: Preset,
                         plan: OptimizerPlan,
                         flags: EngineFlags,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws -> Int {
        do {
            // Attempt 1: creation date + poster (as configured).
            return try await compressImpl(source: source, output: output, preset: preset,
                                          plan: plan, flags: flags, onProgress: onProgress,
                                          allowMetadata: !PrivacyScrub.sessionDisabled,
                                          allowPoster: true)
        } catch CompressionError.metadataRejected {
            // Something in the metadata was refused. Step DOWN, don't nuke:
            // with a poster set, the POSTER is the prime suspect — retry once
            // with the date still in place. Only when the date itself is
            // refused does the session-wide kill switch flip (a missing date
            // is a report warning; a failed job is not).
            if plan.posterData != nil {
                do {
                    return try await compressImpl(source: source, output: output, preset: preset,
                                                  plan: plan, flags: flags, onProgress: onProgress,
                                                  allowMetadata: true, allowPoster: false)
                } catch CompressionError.metadataRejected {
                    PrivacyScrub.sessionDisabled = true
                    return try await compressImpl(source: source, output: output, preset: preset,
                                                  plan: plan, flags: flags, onProgress: onProgress,
                                                  allowMetadata: false, allowPoster: false)
                }
            }
            PrivacyScrub.sessionDisabled = true
            return try await compressImpl(source: source, output: output, preset: preset,
                                          plan: plan, flags: flags, onProgress: onProgress,
                                          allowMetadata: false, allowPoster: false)
        }
    }

    private static func compressImpl(source: URL,
                             output: URL,
                             preset: Preset,
                             plan: OptimizerPlan,
                             flags: EngineFlags,
                             onProgress: @escaping @Sendable (Double) -> Void,
                             allowMetadata: Bool,
                             allowPoster: Bool) async throws -> Int {

        // Stall watchdog — declared before the pipe functions so they can
        // capture it. Every progress report re-arms it; the deadline only
        // fires when the encode GENUINELY stops progressing (a wall-clock
        // timer would wrongly fire the instant the app resumed from
        // suspension, executing a healthy encode).
        let heartbeat = StallWatchdog()

        try? FileManager.default.removeItem(at: output)

        let asset = AVURLAsset(url: source)
        let videoTracks = try? await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks?.first else {
            throw CompressionError.noVideoTrack
        }

        let tags = await ColorTags.from(track: track)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        // Web-optimized MP4 structure (more aggressive interleaving for
        // progressive network playback) — the outputs are shared/streamed
        // far more often than they are archived. NOTE: this lives on the
        // WRITER — there is no per-input property (CI proved the input-level
        // variant does not exist).
        writer.shouldOptimizeForNetworkUse = true

        // ------------------------------------------------------------------
        // REAL HDR → SDR (opt-in, plan.sdrConvert): the conversion is done
        // by AVFoundation ITSELF. The reader runs a video composition whose
        // color triplet is declared Rec.709; the system then decodes the
        // HDR source (HLG or PQ), tone-maps it into SDR, converts the
        // primaries, bakes the rotation and scales to renderSize — one
        // system pipeline, no custom kernels. (Core Image cannot compile
        // Metal kernels at runtime — CIKernel(source:) only accepts the
        // legacy kernel language, a verified CI red round proved it.)
        // `neutralTags` is the canonical SDR triplet (709 transfer/primaries;
        // 601 matrix on SD, 709 on HD) and becomes the tags of EVERYTHING
        // downstream — writer settings AND the appended buffers.
        // ------------------------------------------------------------------
        let neutralTags = ColorTags(primaries: nil, transferFunction: nil, yCbCrMatrix: nil)
        let sdrConvert = plan.sdrConvert

        // ------------------------------------------------------------------
        // PRIVACY SCRUB — deliberate now, accidental before: the writer never
        // carried a metadata track at all, so a re-compressed file lost its
        // creation date as a side effect. The output gets the source's
        // creation date — never a location tag. GPS would only land here via
        // a copied metadata track; none is copied.
        // POSTER: a user-picked image from setup is embedded as QuickTime
        // artwork — Files/Finder use it as the video's icon, players as the
        // poster.
        // Loaded ASYNC here (this engine runs off the main actor); and if the
        // writer refuses to start with the items, compress()'s wrapper
        // retries once with NO metadata and flips the session-wide kill
        // switch.
        // ------------------------------------------------------------------
        var metadata: [AVMetadataItem] = allowMetadata
            ? await PrivacyScrub.items(for: asset)
            : []
        // The poster arrives normalized (JPEG ≤1024px) from setup. The
        // COMMON artwork identifier maps onto the container's own cover-art
        // representation (the QuickTime-scoped one was the on-device crash
        // suspect for the sibling creation-date key).
        if allowPoster, let poster = plan.posterData {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierArtwork
            item.dataType = kCMMetadataBaseDataType_JPEG as String
            item.value = poster as NSData
            metadata.append(item)
        }
        writer.metadata = metadata

        // ------------------------------------------------------------------
        // VIDEO input settings — handed directly to VideoToolbox.
        // ------------------------------------------------------------------
        // GOP: 2 s for camera content; 8 s when the lecture recipe is on
        // (forced mono marks it) — static slides waste bits on frequent
        // keyframes.
        let gopSeconds: Double = (preset.audioChannels == 1) ? 8 : 2
        var props: [String: Any] = [
            AVVideoAverageBitRateKey: plan.videoBitrate,
            AVVideoMaxKeyFrameIntervalKey: max(1, Int(Double(plan.fps) * gopSeconds)),
            AVVideoExpectedSourceFrameRateKey: max(1, Int(plan.fps)),
            AVVideoAllowFrameReorderingKey: NSNumber(value: true),
            // Peak cap: keep bitrate spikes at ~125% of the target (bytes/s
            // over a 1 s window) so fewer jobs need the measured re-encode.
            // VT accepts the "limit/duration" string form; invalid values are
            // logged and ignored by the encoder.
            kVTCompressionPropertyKey_DataRateLimits as String:
                "\(Int((Double(plan.videoBitrate) / 8.0) * 1.25))/1",
            // NOTE: no explicit RealTime key here — expectsMediaDataInRealTime
            // = false (set on the input below) already drives the VideoToolbox
            // session into offline mode; kVTCompressionPropertyKey_RealTime
            // was redundant.
        ]

        // ------------------------------------------------------------------
        // CODEC. H.264 is 8-bit only: feeding it the 10-bit decoded buffers
        // of an HDR source makes every append fail (or produces a mis-tagged
        // file at best). 10-bit sources are therefore ALWAYS encoded as HEVC.
        // The 10-bit HEVC path requests Main10 EXPLICITLY below (the earlier
        // claim that HEVC profile constants aren't exported turned out to be
        // wrong — only the pixel-transfer MODE constants are macro-only);
        // 8-bit HEVC stays on auto-profile negotiation.
        //
        // DECODE vs ENCODE depth: on the normal path the DECODE follows the
        // SOURCE (10-bit HDR stays 10-bit) and the ENCODE with it. With a
        // requested SDR conversion the composition RENDERS 8-bit SDR, so
        // H.264 is legal again and Main10 is NOT requested.
        // ------------------------------------------------------------------
        let wants10Bit = plan.isHDR || plan.sourceBitDepth >= 10
        let encode10Bit = wants10Bit && !sdrConvert
        let encodeCodec: VideoCodec = (encode10Bit && preset.codec == .h264) ? .hevc : preset.codec
        if encodeCodec == .h264 {
            // H.264: High profile — better compression than Main at the same
            // compatibility (High has decoded everywhere for a decade).
            props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        } else if encode10Bit {
            // 10-bit/HDR sources: EXPLICIT Main10 instead of trusting the
            // auto-negotiation — and the verifier re-parses the output's own
            // hvcC atom to prove the depth survived (never take it on faith).
            props[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        }

        let fmts: [CMFormatDescription] = (try? await track.load(.formatDescriptions)) ?? []
        let hint: CMFormatDescription? = fmts.first

        // ------------------------------------------------------------------
        // SCALING DECISION + writer geometry.
        // The writer's geometry must exactly match the buffers appended to it:
        //  * scale path            → plan.outputSize
        //  * direct (keep-res) path → the source's ENCODED dimensions from the
        //    format description (naturalSize is the post-rotation display size)
        //
        // ALL scales (8-bit and 10-bit alike) run through VideoToolbox's
        // pixel transfer session — a pure geometric rescale: no tonemapping,
        // no bit-depth loss, color metadata re-applied onto the destination
        // buffer (color-safe).
        // ------------------------------------------------------------------
        var scaleNeeded = plan.scaleNeeded

        // ROTATE-AWARE GEOMETRY. plan.outputSize is the *display* size (post-
        // rotation, e.g. 480×854 for a portrait video). The encoder writes
        // pre-rotation frames and carries the preferredTransform in the output,
        // so under a 90°/270° rotation the ENCODED frame must be the transposed
        // size (854×480) — this is what makes portrait videos scaleable at all.
        // (Preset.outputSize emits even numbers; swapping even W/H keeps them
        // even, so H.264/HEVC's even-dimension requirement always holds.)
        let preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
        let rotationDegrees = Int(abs(atan2(preferredTransform.b, preferredTransform.a)
                                      * 180 / .pi).rounded())
        let swapsDims = rotationDegrees % 180 == 90

        // USER ROTATION matrix (display space): maps the scaled display
        // frame into the rotated canvas without negative coordinates. The
        // encoded frame geometry is NOT changed by rotation — it rides in
        // the track transform and players apply it at playback.
        let userRotation: CGAffineTransform
        switch plan.rotationDegrees {
        case 90:
            userRotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0,
                                             tx: plan.outputSize.height, ty: 0)
        case 180:
            userRotation = CGAffineTransform(a: -1, b: 0, c: 0, d: -1,
                                             tx: plan.outputSize.width, ty: plan.outputSize.height)
        case 270:
            userRotation = CGAffineTransform(a: 0, b: -1, c: 1, d: 0,
                                             tx: 0, ty: plan.outputSize.width)
        default:
            userRotation = .identity
        }

        let targetW = Int(plan.outputSize.width)
        let targetH = Int(plan.outputSize.height)
        var encodeW = swapsDims ? targetH : targetW
        var encodeH = swapsDims ? targetW : targetH
        if !scaleNeeded, let f = hint {
            let d = CMVideoFormatDescriptionGetDimensions(f)
            if d.width > 0 && d.height > 0 {
                var w = Int(d.width)
                var h = Int(d.height)
                // 4:2:0 encoders require EVEN dimensions: a source stored at
                // odd width/height (rare but real) cannot ship through the
                // direct path — even the geometry (never exceeding the
                // source) and route through the pixel-transfer session
                // instead (a 1-px scale, aspect shift ≤ 0.1%).
                if w % 2 != 0 || h % 2 != 0 {
                    scaleNeeded = true
                    w -= w % 2
                    h -= h % 2
                }
                encodeW = w
                encodeH = h
            }
        }
        if sdrConvert {
            // The composition bakes the rotation and renders at the plan's
            // DISPLAY size. The source-format dims above are pre-rotation —
            // they must NOT override the writer geometry on this path, and
            // the writer's transform below stays IDENTITY (the rotation is
            // already inside the pixels).
            encodeW = Int(plan.outputSize.width)
            encodeH = Int(plan.outputSize.height)
        }

        // One pixel-transfer session for ANY downscale (8-bit SDR included) —
        // created whenever the scale path is active, whether the scale was
        // plan-requested or forced above by odd source dimensions.
        let transferSession: VTPixelTransferSession? = (scaleNeeded && !sdrConvert)
            ? makeTransferSession()
            : nil
        // Extremely unlikely fallback: if the transfer session could not be
        // created, keep the source resolution rather than risk mangling.
        scaleNeeded = scaleNeeded && transferSession != nil

        var settings: [String: Any] = [
            AVVideoCodecKey: encodeCodec.avCodecType,
            AVVideoWidthKey: encodeW,
            AVVideoHeightKey: encodeH,
            AVVideoCompressionPropertiesKey: props,
        ]
        // NOTE ON SOFTWARE ENCODING: there is none on iOS. A request that
        // forbids the hardware encoder (encoder specification with
        // EnableHardwareAcceleratedVideoEncoder = false) compiled fine but
        // CRASHED on device with an uncatchable exception at writer setup —
        // AVFoundation on iOS does not ship a selectable software video
        // encoder. The quality levers that DO exist are the offline session
        // (expectsMediaDataInRealTime = false), Main10 for HDR, and the
        // measured re-encode passes; a true software path would require a
        // full VTCompressionSession pipeline.
        // Always complete — the resolver produces a full, valid triplet
        // (never a partial dictionary). The SD/HD decision uses the shared
        // isSD rule on the SOURCE display size — the same inputs attach()
        // uses, so the buffer-path and writer-path colorimetry agree by
        // construction (max≤720 AND min≤576: 720×1280 portrait is NOT SD).
        // With SDR conversion the SDR triplet REPLACES the source's HDR
        // resolution — tags and pixels must tell the same story.
        settings[AVVideoColorPropertiesKey] = (sdrConvert ? neutralTags : tags)
            .writerColorProperties(
                sd: ColorTags.isSD(width: Int(plan.source.sourceSize.width),
                                   height: Int(plan.source.sourceSize.height)))

        // FORMAT HINT: only truthful when the output will actually look like
        // the source's compressed format. It is cleared when
        //  · the SDR composition re-renders 8-bit 709 (the source is 10-bit
        //    HDR — the buffers appended are NOT the hinted format), or
        //  · the preset's codec family differs from the source's — a hint
        //    describing HEVC while the writer encodes H.264 (compatibility
        //    presets) can misconfigure the encoder just the same.
        let sourceIsHEVC = plan.source.codecSubType == "hvc1"
            || plan.source.codecSubType == "hev1"
        let sourceIsAVC = plan.source.codecSubType == "avc1"
        let hintMatches = encodeCodec == .hevc ? sourceIsHEVC : sourceIsAVC
        let videoInput = AVAssetWriterInput(mediaType: .video,
                                            outputSettings: settings,
                                            sourceFormatHint: (sdrConvert || !hintMatches) ? nil : hint)
        videoInput.expectsMediaDataInRealTime = false
        // TRANSFORM: the source's own rotation is preserved on every path
        // EXCEPT the SDR composition path (there it is baked into the
        // rendered pixels — applying the transform again would rotate the
        // video twice). The USER rotation composes on top in display space:
        // encoded frame → source transform → user rotation.
        if sdrConvert {
            if plan.rotationDegrees != 0 {
                videoInput.transform = userRotation
            }
        } else if !preferredTransform.isIdentity {
            videoInput.transform = preferredTransform.concatenating(userRotation)
        } else if plan.rotationDegrees != 0 {
            videoInput.transform = userRotation
        }
        writer.add(videoInput)

        // ------------------------------------------------------------------
        // AUDIO detection (always re-encoded to AAC at the preset's budget).
        // ------------------------------------------------------------------
        var audioTrack: AVAssetTrack?
        var audioSampleRate = 48000.0
        var audioChannels = 2
        if let aTracks = try? await asset.loadTracks(withMediaType: .audio),
           let aTrack = aTracks.first {
            audioTrack = aTrack
            let aFmts: [CMFormatDescription] = (try? await aTrack.load(.formatDescriptions)) ?? []
            if let aFmt = aFmts.first {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(aFmt)?.pointee {
                    audioSampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
                    // Channel count: the PRESET may force mono (lecture /
                    // screen-recording mode); otherwise the source's own
                    // layout is kept (mono/stereo/5.1; AAC supports it).
                    audioChannels = max(1, Int(asbd.mChannelsPerFrame))
                }
            }
        }
        if let forced = preset.audioChannels {
            audioChannels = forced
        }

        // ------------------------------------------------------------------
        // AAC settings are validated with canApply BEFORE startWriting —
        // AVFoundation is strict above stereo (a channel layout is expected)
        // and about bitrate/channel/sample-rate combinations. An invalid
        // combo would otherwise fail at startWriting and kill the JOB, not
        // just the audio.
        //
        // The ladder steps DOWN only, starting at the budgeted rate: for a
        // target-size plan the audio share was subtracted from the budget,
        // so encoding MORE audio than budgeted (the old 96 kbps floor)
        // would silently break the guarantee. Mono voice is capped at
        // 96 kbps — a mono speech track can't use more.
        // ------------------------------------------------------------------
        let encoderChannels = audioChannels
        let requestedAudioRate = encoderChannels == 1
            ? min(plan.audioBitrate, 96_000)
            : plan.audioBitrate
        // Candidates keep the channel count; rates step DOWN ONLY from the
        // budgeted rate — a stereo preset budgeting 96 kbps must not get
        // bumped to 128 kbps, and a mono plan at 48 kbps must not climb to
        // 64. Filters BELOW the requested rate keep that a hard rule at any
        // budget. The FIRST accepted one wins (the applied rate returns to
        // the coordinator for the report).
        let steps = encoderChannels == 1
            ? [64_000, 48_000, 32_000]
            : [128_000, 96_000, 64_000, 32_000]
        let audioRateCandidates = [requestedAudioRate]
            + steps.filter { $0 < requestedAudioRate }
        var audioSettings: [String: Any]? = nil
        for rate in audioRateCandidates {
            let candidate = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: encoderChannels,
                AVEncoderBitRateKey: max(32_000, rate),
            ] as [String: Any]
            if writer.canApply(outputSettings: candidate, forMediaType: .audio) {
                audioSettings = candidate
                break
            }
        }
        stereoFallback: if audioSettings == nil, encoderChannels != 2 {
            // Channel-count-specific combos (mono layouts on odd sources)
            // can be rejected wholesale: step to plain stereo and retry.
            for rate in audioRateCandidates {
                let candidate = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: audioSampleRate,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: max(32_000, rate),
                ] as [String: Any]
                if writer.canApply(outputSettings: candidate, forMediaType: .audio) {
                    audioSettings = candidate
                    audioChannels = 2
                    break stereoFallback
                }
            }
        }
        if audioSettings == nil {
            // Looks unusable at any config — ship without audio rather than
            // failing the whole job (audio returns 0, the report counts
            // video only).
            NSLog("VidCompress: no acceptable AAC config — shipping video without audio")
        }

        let reader = try AVAssetReader(asset: asset)

        // ------------------------------------------------------------------
        // VIDEO reader output — we ALWAYS decode to pixel buffers because the
        // writer input is configured to re-encode via VideoToolbox. Feeding
        // compressed samples (outputSettings: nil) into such an input is
        // invalid. Bit depth is preserved on every path: 10-bit/HDR sources
        // decode to 10-bit YCbCr (color-safe engine).
        // ------------------------------------------------------------------
        let decodeFormat: OSType = wants10Bit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        // ------------------------------------------------------------------
        // VIDEO OUTPUT: two shapes.
        //  · SDR conversion → a VIDEO COMPOSITION output. Declaring the 709
        //    triplet + renderSize makes AVFoundation decode the HDR source,
        //    tone-map it into SDR (both HLG and PQ), convert primaries,
        //    bake rotation and scale — we append the READY buffers.
        //    If a composition can't be built for the asset the job fails
        //    LOUDLY here (the color pillar would rather fail than
        //    silently ship HDR pixels tagged as SDR).
        //  · Normal path → a TRACK output; bit depth preserved (10-bit for
        //    HDR — the color-safe engine).
        // ------------------------------------------------------------------
        let videoOut: AVAssetReaderOutput
        if sdrConvert {
            do {
                let comp = try await AVMutableVideoComposition
                    .videoComposition(withPropertiesOf: asset)
                comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
                comp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
                comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
                // SCALE, NOT CROP: shrinking renderSize alone cuts the canvas
                // down to its top-left region — the layer instruction must
                // CARRY the scale (source rotation transform first, then the
                // display→render scale), or "720p + Convert to SDR" would
                // output the top-left 1280×720 crop of the full frame.
                let display = plan.source.sourceSize   // rotation-aware display size
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                layer.setTransform(preferredTransform.concatenating(
                    CGAffineTransform(
                        scaleX: display.width > 0 ? CGFloat(encodeW) / display.width : 1,
                        y: display.height > 0 ? CGFloat(encodeH) / display.height : 1)),
                    at: .zero)
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(
                    start: .zero,
                    duration: try await asset.load(.duration))
                instruction.layerInstructions = [layer]
                comp.instructions = [instruction]
                comp.renderSize = CGSize(width: encodeW, height: encodeH)
                let compOut = AVAssetReaderVideoCompositionOutput(
                    videoTracks: [track],
                    videoSettings: [
                        kCVPixelBufferPixelFormatTypeKey as String:
                            NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                    ])
                compOut.videoComposition = comp
                videoOut = compOut
            } catch {
                throw CompressionError.writerFailed(
                    "SDR conversion requested, but no video composition could be built for this asset (\(error.localizedDescription))")
            }
        } else {
            videoOut = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: decodeFormat)
            ])
        }
        // The pipes never retain a sample beyond the loop iteration that
        // fetched it (appends copy synchronously), so the reader's defensive
        // per-sample copy is wasted work — a full-frame memcpy per frame on
        // the direct path.
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)

        var scalePool: CVPixelBufferPool?
        // The pool feeds the SCALING path only (bit-depth preserving).
        // The SDR composition path needs no pool: it hands us finished
        // 8-bit SDR buffers of exactly the writer's geometry.
        if scaleNeeded {
            let poolAttrs: [String: Any] = [
                String(kCVPixelBufferPixelFormatTypeKey): NSNumber(value: decodeFormat),
                String(kCVPixelBufferWidthKey): encodeW,
                String(kCVPixelBufferHeightKey): encodeH,
                // IOSurface-backed buffers: zero-copy handoff into the VT
                // encoder path (plain malloc-backed buffers get copied).
                String(kCVPixelBufferIOSurfacePropertiesKey): [String: Any](),
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, nil, &scalePool)
        }

        var audioInput: AVAssetWriterInput?
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack, let aSettings = audioSettings {
            // The READER's PCM channel count must match the audio input's
            // final fallback (mono source + stereo fallback used to read
            // mono PCM while the writer expected stereo).
            //
            // SAFETY: init(track:outputSettings:) is NOT a throwing
            // initializer in Swift — a settings failure surfaces as an
            // Objective-C exception, which Swift CANNOT catch. The do/catch
            // here was dead weight (compile-warning `try`, never-running
            // `catch`) in front of a potential crash. The SAFE gate is
            // `canAdd`, checked below BEFORE anything is attached to the
            // reader/writer; a rejection ships video-only.
            let readerChannels = (aSettings[AVNumberOfChannelsKey] as? NSNumber)?.intValue
                ?? audioChannels
            var readerSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: readerChannels,
            ]
            if readerChannels == 2 {
                // Explicit stereo layout: downmixing a multichannel (5.1)
                // source to 2ch is NOT guaranteed to be honoured without one.
                var layout = AudioChannelLayout()
                layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
                readerSettings[AVChannelLayoutKey] = Data(
                    bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            } else if readerChannels == 1 {
                // Explicit MONO layout: the lecture/screen-recording mode
                // downmixes multi-channel sources to a mono voice track —
                // same guarantee as the stereo branch.
                var layout = AudioChannelLayout()
                layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
                readerSettings[AVChannelLayoutKey] = Data(
                    bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            }

            let candidateOutput = AVAssetReaderTrackOutput(
                track: audioTrack, outputSettings: readerSettings)
            let candidateInput = AVAssetWriterInput(mediaType: .audio,
                                                    outputSettings: aSettings)
            candidateInput.expectsMediaDataInRealTime = false
            // Same rationale as the video output: PCM blocks are consumed
            // within their loop iteration — skip the defensive copy.
            candidateOutput.alwaysCopiesSampleData = false

            if reader.canAdd(candidateOutput) && writer.canAdd(candidateInput) {
                reader.add(candidateOutput)
                writer.add(candidateInput)
                audioInput = candidateInput
                audioOutput = candidateOutput
            } else {
                // Ship the video without audio — the writer is still in the
                // "adding inputs" phase, so simply not adding the audio
                // input keeps finishWriting() from waiting on a starving
                // track.
                NSLog("VidCompress: audio pipeline rejected the settings — shipping video without audio")
                audioInput = nil
                audioOutput = nil
            }
        }

        // Pixel-buffer adaptor: used on the scaling path only. Geometry and
        // format mirror the pool attributes above (what the WRITER expects).
        let adaptor: AVAssetWriterInputPixelBufferAdaptor? = scaleNeeded ? {
            let poolAttrs: [String: Any] = [
                String(kCVPixelBufferPixelFormatTypeKey): NSNumber(value: decodeFormat),
                String(kCVPixelBufferWidthKey): encodeW,
                String(kCVPixelBufferHeightKey): encodeH,
                String(kCVPixelBufferIOSurfacePropertiesKey): [String: Any](),
            ]
            return AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
                                                        sourcePixelBufferAttributes: poolAttrs)
        }() : nil

        // TRIM: bound the WHOLE read (video AND audio) to the user's window
        // on the raw timeline (output timeline + the probe's anchor offset).
        // Must be set before the reader starts.
        if let trimEnd = plan.trimEnd {
            let rawStart = plan.source.startOffset + plan.trimStart
            let rawEnd = plan.source.startOffset + trimEnd
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: max(0, rawStart), preferredTimescale: 600),
                end: CMTime(seconds: rawEnd, preferredTimescale: 600))
        }
        guard reader.startReading() else {
            throw CompressionError.readerFailed(reader.error?.localizedDescription ?? "could not start reading")
        }
        guard writer.startWriting() else {
            // Metadata is the SUSPECT when it was set: surface a distinct,
            // catchable error so compress() can retry once without it (the
            // writer is single-use — a plain retry on the same instance is
            // impossible, the wrapper rebuilds everything).
            if allowMetadata, !writer.metadata.isEmpty {
                reader.cancelReading()
                throw CompressionError.metadataRejected(
                    writer.error?.localizedDescription
                        ?? "startWriting failed while metadata was set")
            }
            throw writer.error ?? CompressionError.writerFailed("startWriting returned false")
        }
        // Session start via the SHARED SessionAnchor helper (the probe
        // subtracts the same anchor from its duration, so plan.duration
        // describes the output timeline and the verifier's duration check
        // cannot false-fail a trimmed clip). 0 is wrong for EDITED/TRIMMED
        // clips, whose first PTS is often above zero — startSession(0)
        // writes an empty lead; a track starting at/below 0 anchors to 0.
        let videoStart = ((try? await track.load(.timeRange))?.start) ?? .zero
        var audioStart: CMTime?
        if let aTrack = audioTrack {
            audioStart = (try? await aTrack.load(.timeRange))?.start
        }
        var sessionStart = SessionAnchor.start(video: videoStart, audio: audioStart)
        // TRIM: the session anchor moves to the trimmed window start — never
        // before it (that would add lead-in), and never earlier than the
        // natural anchor (tracks starting after the window keep their offset).
        if plan.trimEnd != nil {
            let rawStart = plan.source.startOffset + plan.trimStart
            let natural = CMTimeGetSeconds(sessionStart)
            sessionStart = CMTime(seconds: max(rawStart, natural), preferredTimescale: 600)
        }
        // ONE anchor, computed once and reused: the session AND the progress
        // math (raw pts would otherwise run ahead on anchored/trimmed clips,
        // reaching 99% before the encode finishes).
        let sessionStartSeconds = CMTimeGetSeconds(sessionStart)
        writer.startSession(atSourceTime: sessionStart)

        let expected = plan.expectedFrames
        // Hard cap on SILENTLY dropped frames (buffer-allocation/transfer
        // failures, NOT the fps cap which is intentional): a handful are a
        // decodable blemish; more than 0.1% means something is genuinely
        // wrong and the job must fail instead of shipping a stuttering file.
        // The video pipe also ABORTS EARLY at the limit — no point burning
        // minutes on frames the job will reject anyway.
        var droppedFrames = 0
        let dropLimit = max(1, expected / 1000)
        var lastReported = 0.0
        var lastReportAt = Date()

        // ------------------------------------------------------------------
        // VIDEO PIPE
        // ------------------------------------------------------------------
        func pipeVideo() async {
            await withCheckedContinuation { cont in
                let resume = ResumeBox(cont)
                let queue = DispatchQueue(label: "vidcompress.video.pipe")
                // Frame-rate cap state lives in FrameCapper (unit-tested).
                var capper = preset.fpsCap.map { FrameCapper(cap: $0) }

                // Count a silently lost frame and ABORT the encode the
                // moment the budget is met. The check must live AT the drop
                // sites — a whole-file failure (every allocation/transfer
                // fails) only `continue`s and would otherwise drop the
                // entire video with no heartbeat, letting the 120 s stall
                // watchdog fire a misleading error.
                func noteDrop() -> Bool {
                    droppedFrames += 1
                    guard droppedFrames > dropLimit else { return false }
                    flags.fail(CompressionError.framesDropped(droppedFrames))
                    reader.cancelReading()
                    resume.resumeOnce()
                    return true
                }

                // Cancel + error hooks: stop the reader, then resume THROUGH
                // this pipe's serial queue so any in-flight block completes
                // BEFORE the continuation pops — the engine may then tear the
                // writer down without any append racing it.
                flags.addCancelHook { [weak resume] in
                    reader.cancelReading()
                    queue.async { resume?.resumeOnce() }
                }

                videoInput.requestMediaDataWhenReady(on: queue) {
                    if resume.isDone { return }
                    while videoInput.isReadyForMoreMediaData {
                        // Bail out when cancelled, when the OTHER pipe already
                        // failed (error set by either hook path), or when the
                        // writer died — otherwise this continuation may never
                        // resume and the job would hang forever.
                        if flags.cancelled || flags.error != nil || writer.status == .failed {
                            reader.cancelReading()
                            resume.resumeOnce()
                            return
                        }
                        guard let sb = videoOut.copyNextSampleBuffer() else {
                            // EOF or reader failure. Do NOT markAsFinished on
                            // a writer that is cancelled/failed already —
                            // that raises. The engine tears the writer down.
                            if reader.status == .failed {
                                flags.fail(CompressionError.readerFailed(
                                    reader.error?.localizedDescription ?? "unknown"))
                            } else if !flags.cancelled, writer.status == .writing {
                                videoInput.markAsFinished()      // clean end of stream
                            }
                            resume.resumeOnce()
                            return
                        }

                        let pts = CMSampleBufferGetPresentationTimeStamp(sb)

                        // Frame-rate cap: the slot-grid cadence math lives in
                        // FrameCapper (unit-tested) — first accepted frame
                        // opens a slot, jitter tolerance inside it, VFR lag
                        // re-anchors.
                        if let capper, !capper.shouldKeep(pts) {
                            continue
                        }

                        if sdrConvert {
                            // The composition already tone-mapped, scaled
                            // and rotation-baked the frame: re-tag the
                            // buffer with the FULL SDR triplet (HDR
                            // sidecars — mastering display, light level —
                            // must never travel into an SDR file, so no
                            // attachment is copied from the source) and
                            // append as-is. append(sample:) carries the
                            // composition's original timestamps.
                            if let img = CMSampleBufferGetImageBuffer(sb) {
                                ColorTags.attach(to: img, tags: neutralTags)
                            }
                            if !videoInput.append(sb) {
                                flags.fail(writer.error
                                    ?? CompressionError.writerFailed("SDR buffer append failed"))
                                resume.resumeOnce()
                                return
                            }
                        } else if scaleNeeded, let src = CMSampleBufferGetImageBuffer(sb) {
                            guard let transfer = transferSession else {
                                if noteDrop() { return }
                                continue
                            }
                            guard let dst = Self.nextPoolBuffer(
                                    scalePool, width: encodeW, height: encodeH,
                                    format: decodeFormat) else {
                                if noteDrop() { return }
                                continue
                            }
                            // COLOR-SAFE: copy the source's full attachment
                            // set (incl. mastering display / light level) and
                            // enforce the three core tags BEFORE any pixels
                            // are written, so the scaler and the writer see
                            // the exact source colorimetry.
                            ColorTags.attach(to: dst, tags: tags, from: src)
                            if VTPixelTransferSessionTransferImage(transfer, from: src, to: dst) != noErr {
                                if noteDrop() { return }
                                continue
                            }
                            // Tagging happens pre-transfer (above); nothing to
                            // do post-transfer — the attachments traveled with
                            // the buffer into the writer.
                            if !(adaptor?.append(dst, withPresentationTime: pts) ?? false) {
                                flags.fail(writer.error
                                    ?? CompressionError.writerFailed("pixel buffer append failed"))
                                resume.resumeOnce()
                                return
                            }
                        } else {
                            // Pass-through: the decoded buffer already carries the
                            // exact source color tags; the writer input was
                            // configured with matching color properties.
                            if !videoInput.append(sb) {
                                flags.fail(writer.error
                                    ?? CompressionError.writerFailed("sample append failed"))
                                resume.resumeOnce()
                                return
                            }
                        }

                        // Heartbeat on EVERY frame (cheap): the stall
                        // watchdog must re-arm continuously, not just when a
                        // throttled progress report happens to land.
                        heartbeat.beat()
                        // Progress derived from the anchored presentation time
                        // (raw source pts would run AHEAD on clips whose
                        // tracks start late — 99% before the encode ends).
                        let secs = CMTimeGetSeconds(pts)
                        let anchored = secs - sessionStartSeconds
                        let p = min(0.99, secs.isFinite
                            ? max(0, anchored.isFinite ? anchored / plan.duration : 0)
                            : 0)
                        if p - lastReported >= 0.002
                            || (p != lastReported
                                && Date().timeIntervalSince(lastReportAt) >= 1.0) {
                            lastReported = p
                            lastReportAt = Date()
                            onProgress(p)
                        }
                    }
                }
            }
        }

        // ------------------------------------------------------------------
        // AUDIO PIPE
        // ------------------------------------------------------------------
        func pipeAudio() async {
            guard let aIn = audioInput, let aOut = audioOutput else { return }
            await withCheckedContinuation { cont in
                let resume = ResumeBox(cont)
                let queue = DispatchQueue(label: "vidcompress.audio.pipe")
                // Same queued-resume strategy as the video pipe: no resume
                // can race an in-flight append.
                flags.addCancelHook { [weak resume] in
                    reader.cancelReading()
                    queue.async { resume?.resumeOnce() }
                }
                aIn.requestMediaDataWhenReady(on: queue) {
                    if resume.isDone { return }
                    while aIn.isReadyForMoreMediaData {
                        // Bail out when cancelled, when the OTHER pipe already
                        // failed, or when the writer died.
                        if flags.cancelled || flags.error != nil || writer.status == .failed {
                            reader.cancelReading()
                            resume.resumeOnce()
                            return
                        }
                        guard let sb = aOut.copyNextSampleBuffer() else {
                            if reader.status == .failed {
                                flags.fail(CompressionError.readerFailed(
                                    reader.error?.localizedDescription ?? "audio decode failed"))
                            } else if !flags.cancelled, writer.status == .writing {
                                aIn.markAsFinished()
                            }
                            resume.resumeOnce()
                            return
                        }
                        // The heart of the encode is AAC — the video pipe
                        // may finish long before this does; the watchdog
                        // must see this pipe alive too.
                        heartbeat.beat()
                        if !aIn.append(sb) {
                            flags.fail(writer.error
                                ?? CompressionError.writerFailed("audio append failed"))
                            resume.resumeOnce()
                            return
                        }
                    }
                }
            }
        }

        // Run both pipes concurrently, guarded by a STALL watchdog: if either
        // pipe stops making progress (its continuation never resuming, a
        // wedged queue block, a wedged reader) the encode fails cleanly
        // instead of hanging the job row forever. Progress heartbeats re-arm
        // the deadline, so a suspend→resume cycle never kills a healthy
        // encode. FLAT 120s stall limit: heartbeats fire on EVERY frame, so a
        // stall is, by definition, "no beat for N seconds" — the old
        // duration*3 rule (~6h for a long film) was meaningless.
        let pipesDone = await AsyncTimeout.runWithHeartbeat(
            watchdog: heartbeat,
            stallSeconds: 120,
            minimumWallClock: 15) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await pipeVideo() }
                group.addTask { await pipeAudio() }
                await group.waitForAll()
            }
        }
        if pipesDone == nil {
            // Wake the pipes through their own queues FIRST (flags.fail runs
            // every registered hook and the pipes unwind via their serial
            // queues) — tearing the writer down mid-append is undefined.
            flags.fail(CompressionError.writerFailed("Encoding stalled and was aborted."))
            try? await Task.sleep(nanoseconds: 200_000_000)
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
            if let transferSession { VTPixelTransferSessionInvalidate(transferSession) }
            try? FileManager.default.removeItem(at: output)
            throw CompressionError.writerFailed("Encoding stalled and was aborted.")
        }

        // Errors FIRST (a real engine error also flips `cancelled`): teardown
        // BEFORE touching finalize — never finishWriting() past a failure,
        // and never spend a 120s finalize window on a writer that died anyway.
        if let e = flags.error {
            if writer.status == .writing { writer.cancelWriting() }
            if let transferSession { VTPixelTransferSessionInvalidate(transferSession) }
            try? FileManager.default.removeItem(at: output)
            throw e
        }

        // Honour a user cancel BEFORE touching finishWriting: calling
        // finishWriting() on an already-cancelled writer is a hard crash.
        // The hooks resume the pipes' continuations only AFTER their in-flight
        // blocks complete, so by now no sample appends can be in flight.
        if flags.cancelled {
            if writer.status == .writing { writer.cancelWriting() }
            if let transferSession { VTPixelTransferSessionInvalidate(transferSession) }
            try? FileManager.default.removeItem(at: output)
            throw CompressionError.cancelled
        }

        // Silent-drop guard: report lost frames honestly instead of shipping
        // an output with gaps the verifier can't plainly catch. (Rare here —
        // the video pipe aborts early at this same limit.)
        if droppedFrames > dropLimit {
            if writer.status == .writing { writer.cancelWriting() }
            if let transferSession { VTPixelTransferSessionInvalidate(transferSession) }
            try? FileManager.default.removeItem(at: output)
            throw CompressionError.framesDropped(droppedFrames)
        }

        // Finalize, capped: a wedged finishWriting (e.g. an input that never
        // finished) must not hold the job forever.
        if writer.status == .writing {
            let finalizeOK = await AsyncTimeout.run(seconds: 120) {
                await writer.finishWriting()
            }
            if finalizeOK == nil {
                if let transferSession { VTPixelTransferSessionInvalidate(transferSession) }
                try? FileManager.default.removeItem(at: output)
                throw CompressionError.writerFailed("Writer failed to finalize the file and was aborted.")
            }
        }
        guard writer.status == .completed else {
            let msg = writer.error?.localizedDescription ?? "writer did not complete"
            if let transferSession { VTPixelTransferSessionInvalidate(transferSession) }
            try? FileManager.default.removeItem(at: output)
            throw CompressionError.writerFailed(msg)
        }

        // Success path: release the pixel transfer session's resources.
        if let transferSession { VTPixelTransferSessionInvalidate(transferSession) }
        heartbeat.beat()
        onProgress(1.0)
        // The applied audio rate is 0 unless an audio input was actually
        // ADDED to the writer: a silent source (no track) or an audio
        // pipeline rejected by canAdd must NOT report a rate — the
        // coordinator writes it into plan.audioBitrate and the correction
        // solver would subtract audio bytes that don't exist.
        return audioInput != nil
            ? (audioSettings?[AVEncoderBitRateKey] as? NSNumber)?.intValue ?? 0
            : 0
    }

    /// Fetch a destination pixel buffer from a pool (falling back to a plain
    /// allocation with the same attributes).
    private static func nextPoolBuffer(_ pool: CVPixelBufferPool?,
                                       width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        if let pool {
            var poolBuf: CVImageBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &poolBuf)
            if let b = poolBuf {
                return b as? CVPixelBuffer
            }
        }
        var newBuf: CVPixelBuffer?
        let attrs: [String: Any] = [
            String(kCVPixelBufferPixelFormatTypeKey): NSNumber(value: format)
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                            attrs as CFDictionary, &newBuf)
        return newBuf
    }
}
