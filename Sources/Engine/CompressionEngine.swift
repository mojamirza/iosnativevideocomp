import AVFoundation
import CoreImage
import CoreVideo
import VideoToolbox

/// Cooperative cancellation shared between the UI and the encoder thread(s).
final class EngineFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var _error: Error?

    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return _error }

    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    func setError(_ e: Error) {
        lock.lock(); if _error == nil { _error = e }; lock.unlock()
    }
}

enum CompressionError: LocalizedError {
    case noVideoTrack
    case readerFailed(String)
    case writerFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The selected file has no video track."
        case .readerFailed(let m): return "Decode failed: \(m)"
        case .writerFailed(let m): return "Encode failed: \(m)"
        case .cancelled: return "Compression was cancelled."
        }
    }
}

/// The pipeline: AVAssetReader → [Core Image] → VideoToolbox (through AVAssetWriter).
///
/// Two paths, both strictly color-safe:
///  * Pass-through  — HDR or "keep resolution": native-format buffers go straight
///                    into the encoder with the source color tags intact. HDR is
///                    never tonemapped and never decoded to a lossy intermediate.
///  * Core Image    — SDR downscaling: buffers decoded to 4:2:0, scaled in a
///                    source-matched working color space, re-tagged with the
///                    source color metadata, and handed to the writer.
enum CompressionEngine {

    private final class StartBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(at pts: CMTime, on writer: AVAssetWriter) {
            lock.lock()
            defer { lock.unlock() }
            if !done {
                writer.startSession(atSourceTime: pts)
                done = true
            }
        }
    }

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

    static func compress(source: URL,
                         output: URL,
                         preset: Preset,
                         plan: OptimizerPlan,
                         flags: EngineFlags,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws {

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
        switch preset.codec {
        case .hevc:
            // HEVC profile is picked automatically by AVFoundation/VideoToolbox;
            // the 10-bit Main10 profile is auto-selected for HDR pass-through.
            break
        case .h264:
            props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264MainAutoLevel
        }

        var settings: [String: Any] = [
            AVVideoCodecKey: preset.codec.avCodecType,
            AVVideoWidthKey: Int(plan.outputSize.width),
            AVVideoHeightKey: Int(plan.outputSize.height),
            AVVideoCompressionPropertiesKey: props,
        ]
        if let color = tags.writerColorProperties() {
            settings[AVVideoColorPropertiesKey] = color
        }

        let fmts: [CMFormatDescription] = (try? await track.load(.formatDescriptions)) ?? []
        let hint: CMFormatDescription? = fmts.first

        let videoInput = AVAssetWriterInput(mediaType: .video,
                                            outputSettings: settings,
                                            sourceFormatHint: hint)
        videoInput.expectsMediaDataInRealTime = false
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
                    audioChannels = max(1, min(2, Int(asbd.mChannelsPerFrame)))
                }
            }
        }

        let reader = try AVAssetReader(asset: asset)

        // ------------------------------------------------------------------
        // VIDEO reader output:
        //   scaling path → sanitized SDR 4:2:0 for Core Image
        //   pass-through → nil = native buffers (HDR-safe)
        // ------------------------------------------------------------------
        let videoOut: AVAssetReaderTrackOutput
        if plan.scaleNeeded {
            videoOut = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            ])
        } else {
            videoOut = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        }
        reader.add(videoOut)

        var audioInput: AVAssetWriterInput?
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            audioOutput = try AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(audioOutput!)

            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: audioChannels,
                AVEncoderBitRateKey: plan.audioBitrate,
            ])
            audioInput?.expectsMediaDataInRealTime = false
            writer.add(audioInput!)
        }

        // Pixel-buffer adaptor used only on the scaling path: its pool produces
        // buffers in exactly the geometry the writer expects.
        let adaptor: AVAssetWriterInputPixelBufferAdaptor? = plan.scaleNeeded ? {
            let poolAttrs: [String: Any] = [
                String(kCVPixelBufferPixelFormatTypeKey):
                    NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                String(kCVPixelBufferWidthKey): Int(plan.outputSize.width),
                String(kCVPixelBufferHeightKey): Int(plan.outputSize.height),
            ]
            return AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
                                                        sourcePixelBufferAttributes: poolAttrs)
        }() : nil

        guard writer.startWriting() else {
            throw writer.error ?? CompressionError.writerFailed("startWriting returned false")
        }

        let starter = StartBox()
        let expected = plan.expectedFrames
        var framesAppended = 0

        // ------------------------------------------------------------------
        // VIDEO PIPE
        // ------------------------------------------------------------------
        func pipeVideo() async {
            await withCheckedContinuation { cont in
                let resume = ResumeBox(cont)
                let lastKept = CMTimeBox()
                let queue = DispatchQueue(label: "vidcompress.video.pipe")

                videoInput.requestMediaDataWhenReady(on: queue) {
                    if resume.isDone { return }
                    while videoInput.isReadyForMoreMediaData {
                        if flags.cancelled {
                            reader.cancelReading()
                            writer.cancelWriting()
                            resume.resumeOnce()
                            return
                        }
                        guard let sb = videoOut.copyNextSampleBuffer() else {
                            if reader.status == .failed {
                                flags.setError(CompressionError.readerFailed(
                                    reader.error?.localizedDescription ?? "unknown"))
                                writer.cancelWriting()
                                resume.resumeOnce()
                                return
                            }
                            videoInput.markAsFinished()      // clean end of stream
                            resume.resumeOnce()
                            return
                        }

                        let pts = CMSampleBufferGetPresentationTimeStamp(sb)

                        // Optional frame-rate cap: drop frames on a steady cadence.
                        if let cap = preset.fpsCap, cap > 0 {
                            let halfSlot = CMTime(value: 1, timescale: CMTimeScale(cap) * 2)
                            if CMTimeCompare(CMTimeSubtract(pts, lastKept.value), halfSlot) < 0 {
                                continue
                            }
                            lastKept.value = pts
                        }

                        starter.run(at: pts, on: writer)

                        if plan.scaleNeeded, let src = CMSampleBufferGetImageBuffer(sb) {
                            guard let dst = nextScaledBuffer(from: adaptor,
                                                             width: Int(plan.outputSize.width),
                                                             height: Int(plan.outputSize.height)) else {
                                continue
                            }
                            let sx = CGFloat(plan.outputSize.width) / CGFloat(CVPixelBufferGetWidth(src))
                            let sy = CGFloat(plan.outputSize.height) / CGFloat(CVPixelBufferGetHeight(src))
                            let scaled = CIImage(cvPixelBuffer: src)
                                .transformed(by: CGAffineTransform(
                                    scaleX: max(0.001, sx), y: max(0.001, sy)))
                                .cropped(to: CGRect(x: 0, y: 0,
                                                    width: Int(plan.outputSize.width),
                                                    height: Int(plan.outputSize.height)))
                            AnalysisCIContext.render(scaled, to: dst)
                            // COLOR-SAFE: re-apply the source color metadata.
                            ColorTags.attach(to: dst, tags: tags)
                            if !(adaptor?.append(dst, withPresentationTime: pts) ?? false) {
                                flags.setError(writer.error
                                    ?? CompressionError.writerFailed("pixel buffer append failed"))
                                writer.cancelWriting()
                                resume.resumeOnce()
                                return
                            }
                        } else {
                            // Pass-through: the decoded buffer already carries the
                            // exact source color tags; the writer input was
                            // configured with matching color properties.
                            if !videoInput.append(sb) {
                                flags.setError(writer.error
                                    ?? CompressionError.writerFailed("sample append failed"))
                                writer.cancelWriting()
                                resume.resumeOnce()
                                return
                            }
                        }

                        framesAppended += 1
                        onProgress(min(0.99, Double(framesAppended) / Double(expected)))
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
                aIn.requestMediaDataWhenReady(on: queue) {
                    if resume.isDone { return }
                    while aIn.isReadyForMoreMediaData {
                        if flags.cancelled {
                            reader.cancelReading()
                            writer.cancelWriting()
                            resume.resumeOnce()
                            return
                        }
                        guard let sb = aOut.copyNextSampleBuffer() else {
                            if reader.status == .failed {
                                flags.setError(CompressionError.readerFailed(
                                    reader.error?.localizedDescription ?? "audio decode failed"))
                                writer.cancelWriting()
                                resume.resumeOnce()
                                return
                            }
                            aIn.markAsFinished()
                            resume.resumeOnce()
                            return
                        }
                        starter.run(at: CMSampleBufferGetPresentationTimeStamp(sb), on: writer)
                        if !aIn.append(sb) {
                            flags.setError(writer.error
                                ?? CompressionError.writerFailed("audio append failed"))
                            writer.cancelWriting()
                            resume.resumeOnce()
                            return
                        }
                    }
                }
            }
        }

        // Run both pipes concurrently, then finalize the file.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pipeVideo() }
            group.addTask { await pipeAudio() }
            await group.waitForAll()
        }

        await writer.finishWriting()

        if flags.cancelled {
            try? FileManager.default.removeItem(at: output)
            throw CompressionError.cancelled
        }
        if let e = flags.error {
            try? FileManager.default.removeItem(at: output)
            throw e
        }
        guard writer.status == .completed else {
            let msg = writer.error?.localizedDescription ?? "writer did not complete"
            try? FileManager.default.removeItem(at: output)
            throw CompressionError.writerFailed(msg)
        }

        onProgress(1.0)
    }

    private static func nextScaledBuffer(from adaptor: AVAssetWriterInputPixelBufferAdaptor?,
                                         width: Int, height: Int) -> CVPixelBuffer? {
        guard let adaptor else { return nil }
        if let pool = adaptor.pixelBufferPool {
            var poolBuf: CVImageBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &poolBuf)
            if let b = poolBuf {
                return b as? CVPixelBuffer
            }
        }
        // Fallback: allocate manually with the same attributes.
        var newBuf: CVPixelBuffer?
        let attrs: [String: Any] = [
            String(kCVPixelBufferPixelFormatTypeKey):
                NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            String(kCVPixelBufferWidthKey): width,
            String(kCVPixelBufferHeightKey): height,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            attrs as CFDictionary, &newBuf)
        return newBuf
    }
}

/// Small mutable CMTime holder for the fps-cap gate.
final class CMTimeBox: @unchecked Sendable {
    var value = CMTime(value: CMTimeValue(-1), timescale: 60)
}
