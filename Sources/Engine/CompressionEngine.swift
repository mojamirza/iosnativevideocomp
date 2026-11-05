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

enum CompressionError: LocalizedError {
    case noVideoTrack
    case readerFailed(String)
    case writerFailed(String)
    case cancelled
    case framesDropped(Int)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The selected file has no video track."
        case .readerFailed(let m): return "Decode failed: \(m)"
        case .writerFailed(let m): return "Encode failed: \(m)"
        case .cancelled: return "Compression was cancelled."
        case .framesDropped(let n):
            return "Buffer starvation while encoding — \(n) frames could not be allocated or transferred, so the output would stutter."
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

        // ------------------------------------------------------------------
        // REAL HDR → SDR (opt-in, plan.sdrConvert): the plan branches the
        // whole pipeline — 10-bit decode, Core Image tone-map kernel
        // (SDRConvert.swift), 8-bit 709 encode. `neutralTags` resolves to
        // the canonical SDR triplet (709 transfer/primaries; 601 matrix on
        // SD, 709 on HD) and becomes the tags of EVERYTHING downstream.
        // A nil converter means the CI kernel failed to compile — the job
        // FAILS LOUDLY rather than silently shipping HDR pixels as "SDR"
        // (the color pillar would rather fail than lie).
        // ------------------------------------------------------------------
        let neutralTags = ColorTags(primaries: nil, transferFunction: nil, yCbCrMatrix: nil)
        let sdrScheme: HDRScheme? = plan.sdrConvert ? HDRScheme(transfer: tags.transferFunction) : nil
        let sdrConverter = sdrScheme != nil ? SDRConverter.shared : nil
        if sdrScheme != nil && sdrConverter == nil {
            throw CompressionError.writerFailed(
                "SDR conversion requested but the tone-map kernel failed to initialize on this device")
        }

        // ------------------------------------------------------------------
        // PRIVACY SCRUB — deliberate now, accidental before: the writer never
        // carried a metadata track at all, so a re-compressed file lost its
        // creation date as a side effect. The output gets EXACTLY one item —
        // the source's creation date — and never a location tag. GPS would
        // only land here via a copied metadata track; none is copied.
        // ------------------------------------------------------------------
        writer.metadata = PrivacyScrub.items(for: asset)

        // ------------------------------------------------------------------
        // VIDEO input settings — handed directly to VideoToolbox.
        // ------------------------------------------------------------------
        var props: [String: Any] = [
            AVVideoAverageBitRateKey: plan.videoBitrate,
            AVVideoMaxKeyFrameIntervalKey: max(1, Int(plan.fps * 2)),
            AVVideoExpectedSourceFrameRateKey: max(1, Int(plan.fps)),
            AVVideoAllowFrameReorderingKey: NSNumber(value: true),
            // Offline (non realtime) VT session => best quality math.
            (kVTCompressionPropertyKey_RealTime as String): NSNumber(value: false),
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
        // DECODE vs ENCODE depth: the DECODE follows the SOURCE (10-bit for
        // HDR sources — the tone-map kernel needs the extra precision), the
        // ENCODE follows the OUTPUT: with a requested SDR conversion the
        // writer expects 8-bit SDR buffers, so H.264 becomes legal again
        // and Main10 is NOT requested.
        // ------------------------------------------------------------------
        let wants10Bit = plan.isHDR || plan.sourceBitDepth >= 10
        let encode10Bit = wants10Bit && sdrScheme == nil
        let encodeCodec: VideoCodec = (encode10Bit && preset.codec == .h264) ? .hevc : preset.codec
        if encodeCodec == .h264 {
            // H.264: explicit down-to-earth profile (8-bit only).
            props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264MainAutoLevel
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
        let transferSession: VTPixelTransferSession? = plan.scaleNeeded
            ? makeTransferSession()
            : nil
        // Extremely unlikely fallback: if the transfer session could not be
        // created, keep the source resolution rather than risk mangling.
        let scaleNeeded = plan.scaleNeeded && transferSession != nil

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

        let targetW = Int(plan.outputSize.width)
        let targetH = Int(plan.outputSize.height)
        var encodeW = swapsDims ? targetH : targetW
        var encodeH = swapsDims ? targetW : targetH
        if !scaleNeeded, let f = hint {
            let d = CMVideoFormatDescriptionGetDimensions(f)
            if d.width > 0 && d.height > 0 {
                encodeW = Int(d.width)
                encodeH = Int(d.height)
            }
        }

        var settings: [String: Any] = [
            AVVideoCodecKey: encodeCodec.avCodecType,
            AVVideoWidthKey: encodeW,
            AVVideoHeightKey: encodeH,
            AVVideoCompressionPropertiesKey: props,
        ]
        // Always complete — the resolver produces a full, valid triplet
        // (never a partial dictionary). The SD/HD decision uses the shared
        // isSD rule on the SOURCE display size — the same inputs attach()
        // uses, so the buffer-path and writer-path colorimetry agree by
        // construction (max≤720 AND min≤576: 720×1280 portrait is NOT SD).
        // With SDR conversion the SDR triplet REPLACES the source's HDR
        // resolution — tags and pixels must tell the same story.
        settings[AVVideoColorPropertiesKey] = (sdrScheme != nil ? neutralTags : tags)
            .writerColorProperties(
                sd: ColorTags.isSD(width: Int(plan.source.sourceSize.width),
                                   height: Int(plan.source.sourceSize.height)))

        let videoInput = AVAssetWriterInput(mediaType: .video,
                                            outputSettings: settings,
                                            sourceFormatHint: hint)
        videoInput.expectsMediaDataInRealTime = false
        // Preserve rotation on every path (the scale path encodes transposed
        // pre-rotation frames; the transform restores the display orientation).
        if !preferredTransform.isIdentity {
            videoInput.transform = preferredTransform
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

        let videoOut = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: decodeFormat)
        ])
        reader.add(videoOut)

        var scalePool: CVPixelBufferPool?
        // The pool feeds BOTH paths that append freshly-created buffers:
        // scaling (bit-depth preserved) and SDR conversion (8-bit out).
        // Format = what the WRITER expects, not what the decoder emits.
        let writesNewBuffers = scaleNeeded || sdrScheme != nil
        let writerFormat: OSType = sdrScheme != nil
            ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            : decodeFormat
        if writesNewBuffers {
            let poolAttrs: [String: Any] = [
                String(kCVPixelBufferPixelFormatTypeKey): NSNumber(value: writerFormat),
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

        // Pixel-buffer adaptor + pool: used on the scaling path AND the SDR-
        // conversion path (which always writes NEW buffers). Geometry and
        // format come from the shared pool attributes above.
        let adaptor: AVAssetWriterInputPixelBufferAdaptor? = writesNewBuffers ? {
            let poolAttrs: [String: Any] = [
                String(kCVPixelBufferPixelFormatTypeKey): NSNumber(value: writerFormat),
                String(kCVPixelBufferWidthKey): encodeW,
                String(kCVPixelBufferHeightKey): encodeH,
                String(kCVPixelBufferIOSurfacePropertiesKey): [String: Any](),
            ]
            return AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
                                                        sourcePixelBufferAttributes: poolAttrs)
        }() : nil

        guard reader.startReading() else {
            throw CompressionError.readerFailed(reader.error?.localizedDescription ?? "could not start reading")
        }
        guard writer.startWriting() else {
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
        // ONE anchor, computed once and reused: the session AND the progress
        // math (raw pts would otherwise run ahead on anchored/trimmed clips,
        // reaching 99% before the encode finishes).
        let sessionStart = SessionAnchor.start(video: videoStart, audio: audioStart)
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
                var nextSlot = CMTime.zero
                var slotActive = false

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

                        // Frame-rate cap on a SLOT GRID with re-anchoring:
                        // each accepted frame opens a slot 1/cap wide; frames
                        // inside the open slot are dropped (first frame
                        // anchors the grid). WITHOUT re-anchoring the grid
                        // drifts: after a slower stretch (variable-rate screen
                        // recordings) nextSlot lags behind and a later burst
                        // passes entirely uncapped. A QUARTER-PERIOD tolerance
                        // below the slot boundary absorbs the timestamp jitter
                        // of a source hovering just above the cap (30.1 fps
                        // at cap 30): without it, an early frame just past the
                        // boundary ditches in and the cadence hitches.
                        if let cap = preset.fpsCap, cap > 0 {
                            let period = CMTime(value: 1, timescale: CMTimeScale(cap))
                            let tol = CMTime(value: 1, timescale: CMTimeScale(cap * 4))
                            if !slotActive {
                                slotActive = true
                                nextSlot = CMTimeAdd(pts, period)
                            } else if CMTimeCompare(pts, CMTimeSubtract(nextSlot, tol)) < 0 {
                                // Still inside the open slot (tolerance edge
                                // included) — kept cadence, drop the frame.
                                continue
                            } else if CMTimeGetSeconds(CMTimeSubtract(pts, nextSlot)) > 2.0 / Double(cap) {
                                // Grid lagged more than a full period: re-
                                // anchor HERE so a follow-up burst is capped
                                // again instead of sliding through.
                                nextSlot = CMTimeAdd(pts, period)
                            } else {
                                nextSlot = CMTimeAdd(nextSlot, period)
                            }
                        }

                        if let scheme = sdrScheme, let src = CMSampleBufferGetImageBuffer(sb) {
                            guard let converter = sdrConverter else {
                                // Guarded at setup (throws) — unreachable, but
                                // a drop here must still respect the budget.
                                if noteDrop() { return }
                                continue
                            }
                            guard let dst = Self.nextPoolBuffer(
                                    scalePool, width: encodeW, height: encodeH,
                                    format: writerFormat) else {
                                if noteDrop() { return }
                                continue
                            }
                            // COLOR-SAFE SDR conversion: the kernel decodes
                            // the transfer, converts primaries, tone-maps and
                            // re-encodes 709 — the buffer's own tags must NOT
                            // leak HDR sidecars (mastering display etc.) into
                            // an SDR file, so the full SDR triplet is attached
                            // on the NEW buffer AFTER the render.
                            do {
                                try converter.render(from: src, to: dst, scheme: scheme)
                            } catch {
                                if noteDrop() { return }
                                continue
                            }
                            ColorTags.attach(to: dst, tags: neutralTags)
                            if !(adaptor?.append(dst, withPresentationTime: pts) ?? false) {
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
            // Abort everything the stalled pipes left behind.
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
