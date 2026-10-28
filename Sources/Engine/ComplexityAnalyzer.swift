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

/// Frame-by-frame analysis with Core Image + Core Video.
///
/// Samples ~16 frames evenly across the whole video, converts each decoded
/// pixel buffer to a clean luminance map through Core Image, then measures:
///  * spatial detail  – per-frame luminance standard deviation
///  * temporal motion  – mean absolute luminance delta between samples
///
/// The resulting score drives the Quality-Size Optimizer.
enum ComplexityAnalyzer {

    static func analyze(url: URL, probe: ProbeResult) async throws -> ComplexityScore {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw NSError(domain: "VidCompress.complexity", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "No video track."])
        }

        let duration = probe.duration
        let fps = probe.nominalFPS > 0 ? probe.nominalFPS : 30
        let totalFrames = max(1, Int(duration * Double(fps)))
        let sampleCount = min(16, max(4, totalFrames / 10))
        let step = max(1, totalFrames / sampleCount)
        var wanted = Set<Int>()
        var i = totalFrames / (sampleCount * 2)
        while wanted.count < sampleCount && i < totalFrames {
            wanted.insert(i)
            i += step
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                NSNumber(value: kCVPixelFormatType_32BGRA)
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "VidCompress.complexity", code: -3)
        }

        var frameIndex = 0
        var lastLuma: [Double]?
        var details: [Double] = []
        var motions: [Double] = []

        while frameIndex < totalFrames && details.count < wanted.count {
            guard let sb = output.copyNextSampleBuffer() else { break }
            if wanted.contains(frameIndex), let buf = CMSampleBufferGetImageBuffer(sb) {
                let luma = luminanceMap(buf)
                if let luma {
                    let mean = luma.reduce(0, +) / Double(luma.count)
                    let variance = luma.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(luma.count)
                    details.append(sqrt(variance))
                    if let last = lastLuma {
                        // Mean absolute difference frame-vs-frame for motion/dyanamics.
                        var sum = 0.0
                        for k in 0..<min(last.count, luma.count) { sum += abs(last[k] - luma[k]) }
                        motions.append(sum / Double(luma.count))
                    }
                    lastLuma = luma
                }
            }
            frameIndex += 1
        }
        reader.cancelReading()

        let avgDetail = details.isEmpty ? 0.12 : details.reduce(0, +) / Double(details.count)
        let avgMotion = motions.isEmpty ? 0.0 : motions.reduce(0, +) / Double(motions.count)

        // Normalisers tuned against typical 8-bit camera footage.
        let detailNorm = min(1.0, avgDetail / 0.115)          // ~ full sRGB span st.dev ≈ 0.115
        let motionNorm = min(1.0, avgMotion / 0.035)
        let value = max(0.08, min(1.0, 0.55 * detailNorm + 0.45 * motionNorm))

        return ComplexityScore(value: value,
                               spatialDetail: avgDetail,
                               motion: avgMotion,
                               sampledFrames: details.count)
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
