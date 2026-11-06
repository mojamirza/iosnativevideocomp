import AVFoundation
import CoreVideo

// =====================================================================
// QUALITY SCORING — the "how good is it really?" companion to the
// target-size guarantee. Samples a handful of frames from the SOURCE
// and the OUTPUT at identical fractions of the timeline, decodes both
// to a small common luma grid, and computes PSNR + SSIM on real pixels.
// Pure math lives in `psnr`/`ssim` (unit-tested); the decode/compare
// loop is bounded (a hard wall-clock budget) so it can never wedge the
// verifier.
// =====================================================================

enum QualityCheck {

    struct LumaFrame {
        let luma: [UInt8]
        let width: Int
        let height: Int
        /// Presentation timestamp (seconds) of the sampled frame. The
        /// verifier uses it to align a non-zero-starting SOURCE with the
        /// output timeline — fraction-of-duration alone compares the wrong
        /// scenes on clipped assets.
        let time: Double
    }

    /// Large enough to catch blockiness at lecture bitrates, small enough
    /// to stay inside the verifier's time budget.
    static let sampleWidth = 640
    /// Reader window for grabbing one frame (keyframe-safe: the reader may
    /// decode from the preceding GOP edge).
    static let readerWindowSeconds = 0.35

    /// Reads ONE frame's 8-bit luma out of `asset` at `seconds` — bounded
    /// window, hardware downscale to `sampleWidth` (aspect-true, even).
    static func lumaFrame(asset: AVURLAsset, at seconds: Double,
                          width: Int = sampleWidth) async -> LumaFrame? {
        guard seconds.isFinite, seconds >= 0,
              let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first else { return nil }
        let natural = (try? await track.load(.naturalSize)) ?? .zero
        guard natural.width > 0, natural.height > 0 else { return nil }
        var height = Int((natural.height / natural.width * Double(width)).rounded())
        if height < 2 { height = 2 }
        if height % 2 == 1 { height += 1 }

        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        // Bounded window around the sample point — the reader decodes from
        // the preceding GOP edge inside this range and stops after it, so
        // one grabbed frame never costs a full-decode of the file.
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
            duration: CMTime(seconds: readerWindowSeconds, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferWidthKey as String: NSNumber(value: width),
            kCVPixelBufferHeightKey as String: NSNumber(value: height),
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        // First decodable frame inside the window carries the sample.
        while let sample = output.copyNextSampleBuffer() {
            defer { reader.cancelReading() }
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard let buffer = CMSampleBufferGetImageBuffer(sample),
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess
            else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let w = CVPixelBufferGetWidthOfPlane(buffer, 0)
            let h = CVPixelBufferGetHeightOfPlane(buffer, 0)
            guard w >= 2, h >= 2, stride >= w,
                  let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
            let plane = base.assumingMemoryBound(to: UInt8.self)
            var luma = [UInt8](repeating: 0, count: w * h)
            for row in 0..<h {
                let start = plane + row * stride
                luma.replaceSubrange(row * w..<(row * w) + w,
                                     with: UnsafeBufferPointer(start: start, count: w))
            }
            return LumaFrame(luma: luma, width: w, height: h, time: time.isFinite ? time : seconds)
        }
        return nil
    }

    /// PSNR over 8-bit luma (higher = closer; identical frames → 99.0 dB
    /// stand-in for infinity). nil when sizes differ (can't compare).
    static func psnr(_ a: LumaFrame, _ b: LumaFrame) -> Double? {
        guard a.luma.count == b.luma.count, !a.luma.isEmpty,
              a.width == b.width, a.height == b.height else { return nil }
        var acc: UInt64 = 0
        for i in a.luma.indices {
            let d = Int(a.luma[i]) - Int(b.luma[i])
            acc += UInt64(d * d)
        }
        let mse = Double(acc) / Double(a.luma.count)
        if mse == 0 { return 99.0 }
        return 10.0 * log10(255.0 * 255.0 / mse)
    }

    /// SSIM over 8×8 non-overlapping luminance windows (standard
    /// mean/variance/covariance form; c1/c2 = the canonical constants).
    /// Identical frames → 1.0. nil when sizes differ.
    static func ssim(_ a: LumaFrame, _ b: LumaFrame) -> Double? {
        guard a.luma.count == b.luma.count, !a.luma.isEmpty,
              a.width == b.width, a.height == b.height else { return nil }
        let w = a.width, h = a.height
        let c1 = 6.5025, c2 = 58.5225        // (0.01·255)², (0.03·255)²
        var total = 0.0
        var windows = 0
        var y = 0
        while y + 8 <= h {
            var x = 0
            while x + 8 <= w {
                var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
                for dy in 0..<8 {
                    let row = (y + dy) * w + x
                    for dx in 0..<8 {
                        let va = Double(a.luma[row + dx])
                        let vb = Double(b.luma[row + dx])
                        sa += va; sb += vb
                        saa += va * va; sbb += vb * vb
                        sab += va * vb
                    }
                }
                let n = 64.0
                let ma = sa / n, mb = sb / n
                let va2 = saa / n - ma * ma
                let vb2 = sbb / n - mb * mb
                let cov = sab / n - ma * mb
                let num = (2 * ma * mb + c1) * (2 * cov + c2)
                let den = (ma * ma + mb * mb + c1) * (va2 + vb2 + c2)
                if den > 0 { total += num / den; windows += 1 }
                x += 8
            }
            y += 8
        }
        guard windows > 0 else { return nil }
        return max(0.0, min(1.0, total / Double(windows)))
    }

    /// Report language for a scored pair. QUALITY IS NOT INTEGRITY: a lower
    /// bitrate preset on hard content lands south of 30 dB without the file
    /// being broken in any way, so only genuinely weak scores warn — bands:
    ///   ≥ 38 dB: excellent · ≥ 30: strong · ≥ 22: acceptable (all pass) ·
    ///   below 22: weak (warn).
    static func grade(psnr: Double, ssim: Double)
        -> (label: String, detail: String, severity: ReportSeverity) {
        switch psnr {
        case ..<22:
            return ("Weak match",
                String(format: "PSNR %.1f dB · SSIM %.2f — visible differences vs the source (aggressive bitrate, scaling or fps capping). Compare the two before deleting the original; consider a higher bitrate.",
                       psnr, ssim), .warn)
        case ..<30:
            return ("Acceptable quality",
                String(format: "PSNR %.1f dB · SSIM %.2f — differences exist, which is expected at this bitrate; the decode is intact.",
                       psnr, ssim), .pass)
        case ..<38:
            return ("Strong quality",
                String(format: "PSNR %.1f dB · SSIM %.2f — the output closely matches the source.", psnr, ssim), .pass)
        default:
            return ("Excellent quality",
                String(format: "PSNR %.1f dB · SSIM %.2f — visually the same pixels as the source.", psnr, ssim), .pass)
        }
    }
}
