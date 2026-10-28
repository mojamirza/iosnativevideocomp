import AVFoundation
import CoreImage
import CoreVideo

/// Copy-free shared CI context for analysis and scaling renders.
let AnalysisCIContext = CIContext(options: [.cacheIntermediates: false])

struct ComplexityScore: Hashable {
    /// 0.0 (flat slides) – 1.0 (extremely dense / fast motion)
    var value: Double
    var spatialDetail: Double
    var motion: Double
    var sampledFrames: Int
}

/// Fast frame analysis with Core Image + Core Video.
///
/// Instead of sequentially decoding every frame of the file (which delayed the
/// estimated-size display for many seconds on long videos), this opens a short
/// independent `AVAssetReader` **window** (~0.4 s) at ~16 evenly spaced points
/// across the video and decodes at most 2 frames inside each window:
///  * spatial detail  – per-frame luminance standard deviation
///  * temporal motion  – mean absolute luminance delta within a window
///
/// Only ~32 frames are decoded regardless of source length, so the analysis
/// finishes in well under a second even for hour-long 4K files.
enum ComplexityAnalyzer {

    /// Total number of sampled windows across the file.
    private static let windowCount = 16

    static func analyze(url: URL, probe: ProbeResult) async throws -> ComplexityScore {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw NSError(domain: "VidCompress.complexity", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "No video track."])
        }

        let duration = max(0.2, probe.duration)
        let sampleCount = min(windowCount, max(4, Int(duration / 1.0)))
        let window = min(0.4, duration / Double(sampleCount))

        var details: [Double] = []
        var motions: [Double] = []

        for i in 0..<sampleCount {
            if Task.isCancelled { throw CancellationError() }

            let startSeconds = duration * Double(i) / Double(sampleCount)
            let start = CMTime(seconds: startSeconds, preferredTimescale: 600)
            let end = CMTime(seconds: min(duration, startSeconds + window), preferredTimescale: 600)

            // Short per-window reader: seeks straight to the window, decodes
            // at most two frames, and is torn down immediately.
            guard let reader = try? AVAssetReader(asset: asset) else { break }
            reader.timeRange = CMTimeRange(start: start, end: end)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    NSNumber(value: kCVPixelFormatType_32BGRA)
            ])
            reader.add(output)
            guard reader.startReading() else { continue }

            var lumaPair: [[Double]] = []
            while lumaPair.count < 2 {
                guard let sb = output.copyNextSampleBuffer(),
                      let buf = CMSampleBufferGetImageBuffer(sb) else { break }
                if let luma = luminanceMap(buf) {
                    lumaPair.append(luma)
                }
            }
            reader.cancelReading()

            guard let first = lumaPair.first else { continue }

            // Spatial detail: luminance standard deviation.
            let mean = first.reduce(0, +) / Double(first.count)
            let variance = first.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(first.count)
            details.append(sqrt(variance))

            // Temporal motion: frame-vs-frame mean absolute difference.
            if lumaPair.count > 1 {
                let second = lumaPair[1]
                var sum = 0.0
                for k in 0..<min(first.count, second.count) {
                    sum += abs(first[k] - second[k])
                }
                motions.append(sum / Double(second.count))
            }
        }

        let avgDetail = details.isEmpty ? 0.12 : details.reduce(0, +) / Double(details.count)
        let avgMotion = motions.isEmpty ? 0.0 : motions.reduce(0, +) / Double(motions.count)

        // Normalisers tuned against typical 8-bit camera footage.
        let detailNorm = min(1.0, avgDetail / 0.115)          // ~ full sRGB span st.dev ≈ 0.115
        let motionNorm = min(1.0, avgMotion / 0.035)
        let value = max(0.08, min(1.0, 0.55 * detailNorm + 0.45 * motionNorm))

        return ComplexityScore(value: value,
                               spatialDetail: avgDetail,
                               motion: avgMotion,
                               sampledFrames: details.count * max(1, min(2, details.count)))
    }

    /// Downscale a decoded Core Video buffer to 64×64 and pull raw luminance values.
    private static func luminanceMap(_ buffer: CVImageBuffer) -> [Double]? {
        let N = 64
        let base = CIImage(cvPixelBuffer: buffer)
        let sx = CGFloat(N) / base.extent.width
        let sy = CGFloat(N) / base.extent.height
        let scaled = base.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .cropped(to: CGRect(x: 0, y: 0, width: N, height: N))

        var bitmap = [UInt8](repeating: 0, count: N * N * 4)
        AnalysisCIContext.render(
            scaled,
            toBitmap: &bitmap,
            rowBytes: N * 4,
            bounds: CGRect(x: 0, y: 0, width: N, height: N),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )
        var luma = [Double](repeating: 0, count: N * N)
        for p in 0..<(N * N) {
            let r = Double(bitmap[p * 4]) / 255.0
            let g = Double(bitmap[p * 4 + 1]) / 255.0
            let b = Double(bitmap[p * 4 + 2]) / 255.0
            luma[p] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return luma
    }
}
