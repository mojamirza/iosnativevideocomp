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
            return "Fell behind while scaling — \(n) frames were lost and the output would stutter."
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
///                         VideoToolbox pixel transfer session in explicit
///                         HighQuality scaling mode. Pure geometric rescale:
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
    /// The default scaling mode is unspecified/driver-dependent — HighQuality
    /// is requested explicitly so 4K→720p doesn't alias.
    private static func makeTransferSession() -> VTPixelTransferSession? {
        var s: VTPixelTransferSession?
        // VTCreatePixelTransferSession is macOS-only; iOS uses the classic call.
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                           pixelTransferSessionOut: &s) == noErr, let s else {
            return nil
        }
        VTSessionSetProperty(s,
                             propertyKey: kVTPixelTransferPropertyKey_ScalingMode,
                             value: kVTPixelTransferScalingMode_HighQuality)
        return s
    }

    static func compress(source: URL,
                         output: URL,
                         preset: Preset,
                         plan: OptimizerPlan,
                         flags: EngineFlags,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws {

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
        // CODEC + PROFILE. H.264 is 8-bit only: feeding it the 10-bit decoded
        // buffers of an HDR source makes every append fail (or produces a
        // mis-tagged file at best). 10-bit sources are therefore ALWAYS
        // encoded as HEVC — with the Main10 profile set explicitly rather
        // than left to auto-negotiation.
        // ------------------------------------------------------------------
        let wants10Bit = plan.isHDR || plan.sourceBitDepth >= 10
        let encodeCodec: VideoCodec = (wants10Bit && preset.codec == .h264) ? .hevc : preset.codec
        switch encodeCodec {
        case .hevc:
            props[AVVideoProfileLevelKey] =
                wants10Bit ? AVVideoProfileLevelH265Main10AutoLevel : AVVideoProfileLevelH265MainAutoLevel
        case .h264:
            props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264MainAutoLevel
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
        if let color = tags.writerColorProperties() {
            settings[AVVideoColorPropertiesKey] = color
        }

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
                    // Keep the source channel layout (mono/stereo/5.1); AAC supports it.
                    audioChannels = max(1, Int(asbd.mChannelsPerFrame))
                }
            }
        }

        // ------------------------------------------------------------------
        // AAC settings are validated with canApply BEFORE startWriting —
        // AVFoundation is strict above stereo (a channel layout is expected)
        // and about bitrate/channel/sample-rate combinations. An invalid
        // combo would otherwise fail at startWriting and kill the JOB, not
        // just the audio. Fallbacks: whatever fails → stereo → safe 128k.
        // ------------------------------------------------------------------
        var audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: audioChannels,
            AVEncoderBitRateKey: plan.audioBitrate,
        ]
        if !writer.canApply(outputSettings: audioSettings, forMediaType: .audio) {
            audioSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: max(96_000, min(256_000, plan.audioBitrate)),
            ]
            if !writer.canApply(outputSettings: audioSettings, forMediaType: .audio) {
                audioSettings[AVEncoderBitRateKey] = 128_000
                if !writer.canApply(outputSettings: audioSettings, forMediaType: .audio) {
                    // Looks unusable at any config — ship without audio
                    // rather than failing the whole job.
                    audioSettings = nil
                }
            }
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
        if scaleNeeded {
            let poolAttrs: [String: Any] = [
                String(kCVPixelBufferPixelFormatTypeKey): NSNumber(value: decodeFormat),
                String(kCVPixelBufferWidthKey): encodeW,
                String(kCVPixelBufferHeightKey): encodeH,
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, nil, &scalePool)
        }

        var audioInput: AVAssetWriterInput?
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack, let aSettings = audioSettings {
            audioOutput = try AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(audioOutput!)

            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
            audioInput?.expectsMediaDataInRealTime = false
            writer.add(audioInput!)
        }

        // Pixel-buffer adaptor used only on the scaling path: its pool produces
        // buffers in exactly the geometry and bit depth the writer expects.
        let adaptor: AVAssetWriterInputPixelBufferAdaptor? = scaleNeeded ? {
            let poolAttrs: [String: Any] = [
                String(kCVPixelBufferPixelFormatTypeKey): NSNumber(value: decodeFormat),
                String(kCVPixelBufferWidthKey): encodeW,
                String(kCVPixelBufferHeightKey): encodeH,
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
        // Single, race-free session start: 0 is <= every sample PTS of both
        // tracks, so neither pipe can append "before the session".
        writer.startSession(atSourceTime: .zero)

        let expected = plan.expectedFrames
        // Hard cap on SILENTLY dropped frames (buffer-allocation/transfer
        // failures, NOT the fps cap which is intentional): a handful are a
        // decodable blemish; more than 0.1% means something is genuinely
        // wrong and the job must fail instead of shipping a stuttering file.
        var droppedFrames = 0
        let dropLimit = max(1, expected / 1000)
        var lastReported = 0.0

        // ------------------------------------------------------------------
        // VIDEO PIPE
        // ------------------------------------------------------------------
        func pipeVideo() async {
            await withCheckedContinuation { cont in
                let resume = ResumeBox(cont)
                let queue = DispatchQueue(label: "vidcompress.video.pipe")
                var nextSlot = CMTime.zero
                var slotActive = false

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

                        // Frame-rate cap on a SLOT GRID: each accepted frame
                        // opens a slot 1/cap wide; frames inside an open slot
                        // are dropped. Steady cadence, correct for any source
                        // rate (and the FIRST frame is always kept — the grid
                        // anchors on it, not on a negative starting point).
                        if let cap = preset.fpsCap, cap > 0 {
                            if !slotActive {
                                slotActive = true
                                nextSlot = pts
                            } else if CMTimeCompare(pts, nextSlot) < 0 {
                                continue
                            }
                            nextSlot = CMTimeAdd(nextSlot, CMTime(value: 1, timescale: CMTimeScale(cap)))
                        }

                        if scaleNeeded, let src = CMSampleBufferGetImageBuffer(sb) {
                            guard let transfer = transferSession else {
                                droppedFrames += 1
                                continue
                            }
                            guard let dst = Self.nextPoolBuffer(
                                    scalePool, width: encodeW, height: encodeH,
                                    format: decodeFormat) else {
                                droppedFrames += 1
                                continue
                            }
                            // COLOR-SAFE: copy the source's full attachment
                            // set (incl. mastering display / light level) and
                            // enforce the three core tags BEFORE any pixels
                            // are written, so the scaler and the writer see
                            // the exact source colorimetry.
                            ColorTags.attach(to: dst, tags: tags, from: src)
                            if VTPixelTransferSessionTransferImage(transfer, from: src, to: dst) != noErr {
                                droppedFrames += 1
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
                        // Progress derived from the presentation TIME, not a
                        // frame count — this stays truthful across frame-rate
                        // caps and variable-frame-rate sources.
                        let secs = CMTimeGetSeconds(pts)
                        let p = min(0.99, secs.isFinite && secs >= 0 ? secs / plan.duration : 0)
                        if p - lastReported >= 0.005 {
                            lastReported = p
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
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw CompressionError.writerFailed("Encoding stalled and was aborted.")
        }

        // Errors FIRST (a real engine error also flips `cancelled`): teardown
        // BEFORE touching finalize — never finishWriting() past a failure,
        // and never spend a 120s finalize window on a writer that died anyway.
        if let e = flags.error {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: output)
            throw e
        }

        // Honour a user cancel BEFORE touching finishWriting: calling
        // finishWriting() on an already-cancelled writer is a hard crash.
        // The hooks resume the pipes' continuations only AFTER their in-flight
        // blocks complete, so by now no sample appends can be in flight.
        if flags.cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw CompressionError.cancelled
        }

        // Silent-drop guard: report lost frames honestly instead of shipping
        // an output with gaps the verifier can't plainly catch.
        if droppedFrames > dropLimit {
            writer.cancelWriting()
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
                try? FileManager.default.removeItem(at: output)
                throw CompressionError.writerFailed("Writer failed to finalize the file and was aborted.")
            }
        }
        guard writer.status == .completed else {
            let msg = writer.error?.localizedDescription ?? "writer did not complete"
            try? FileManager.default.removeItem(at: output)
            throw CompressionError.writerFailed(msg)
        }

        heartbeat.beat()
        onProgress(1.0)
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
