import XCTest
import Metal
import CoreVideo
import CoreImage
@testable import VidCompress

/// The HDR → SDR contract: reference math first (pure, no GPU), then — when
/// a Metal device exists — the actual Core Image render path against the
/// same reference. These tests are what makes "never fake a conversion"
/// enforceable in CI.
final class SDRConvertTests: XCTestCase {

    // HLG scene-linear at the diffuse-white signal (E′ = 0.75) ≈ 0.2666 —
    // the anchor shared with PQ (203 nits).
    func testHLGDiffuseAnchor() {
        let lin = SDRMath.hlgToLinear(0.75)
        XCTAssertEqual(lin, SDRMath.hlgDiffuseLinear, accuracy: 0.005)
        // Applying the gain must land at (≈) SDR white, E′709 ≈ 1.0 output.
        XCTAssertEqual(SDRMath.convert(0.75, scheme: .hlg), 0.99, accuracy: 0.02)
    }

    // BT.709 OETF reference point.
    func testEncode709Reference() {
        XCTAssertEqual(SDRMath.encode709(0.15), 0.3691, accuracy: 0.002)
        // Linear segment below the knee: E = 0.01 → E′ = 0.045.
        XCTAssertEqual(SDRMath.encode709(0.01), 0.045, accuracy: 0.0001)
    }

    // PQ is absolute: E′ = 1.0 is the 10 000-nit peak → Y = 1.0.
    func testPQPeak() {
        XCTAssertEqual(SDRMath.pqToLinear(1.0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(SDRMath.pqToLinear(0.0), 0.0, accuracy: 1e-9)
    }

    // The 2020→709 linear matrix rows each sum to (≈) 1.0 — neutral gray maps
    // to neutral gray, the basic sanity of any primaries conversion.
    func testMatrixRowsSumToOne() {
        let r = SDRMath.bt2020To709(1, 0, 0)
        let g = SDRMath.bt2020To709(0, 1, 0)
        let b = SDRMath.bt2020To709(0, 0, 1)
        let rows = [
            r.r + g.r + b.r,
            r.g + g.g + b.g,
            r.b + g.b + b.b,
        ]
        for row in rows {
            XCTAssertEqual(row, 1.0, accuracy: 0.001)
        }
    }

    // Monotonicity: brighter HLG in → brighter (or equal) SDR out; white maps
    // into the top band; black stays black.
    func testConversionIsMonotonic() {
        var prev = SDRMath.convert(0.0, scheme: .hlg)
        XCTAssertEqual(prev, 0.0, accuracy: 1e-6)
        for s in stride(from: 0.05, through: 1.0, by: 0.05) {
            let next = SDRMath.convert(s, scheme: .hlg)
            XCTAssertGreaterThanOrEqual(next, prev, "HLG \(s) must not invert")
            XCTAssertGreaterThanOrEqual(next, 0.0, accuracy: 1e-6)
            XCTAssertLessThanOrEqual(next, 1.0, accuracy: 1e-6)
            prev = next
        }
    }

    // ------------------------------------------------------------------
    // FULL PIPELINE (requires Metal; skips cleanly on GPU-less runners):
    // an HLG-tagged synthetic source (Y ≈ 180 limited-range ≈ E′ = 0.75,
    // neutral chroma) must come out at SDR-white luma in an 8-bit 420v
    // destination — reference math and GPU kernel agree through the whole
    // decode→tone-map→re-encode chain. An 8-bit source is used (not the
    // real engine's 10-bit decode) because 'x420' bit justification inside
    // CVPixelBuffer would make synthetic fills platform-ambiguous; the
    // kernel consumes NORMALIZED YUV→RGB either way, so the math chain is
    // validated identically.
    // ------------------------------------------------------------------
    func testFullPipelineRendersSDRWhite() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device on this runner — reference math covered above")
        }
        guard let converter = SDRConverter.shared else {
            XCTFail("SDRConverter kernel failed to compile — the conversion can never ship")
            return
        }

        let w = 64, h = 32
        // 8-bit 4:2:0 video-range source ('420v'), HLG transfer attached —
        // exactly what "an encoded HDR frame" presents to the converter.
        var src: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            nil, &src)
        guard let srcBuf = src else {
            XCTFail("source buffer creation failed"); return
        }
        // The engine decodes HDR buffers with the SOURCE's tags attached.
        CVBufferSetAttachment(srcBuf, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                              .shouldPropagate)
        CVBufferSetAttachment(srcBuf, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)

        CVPixelBufferLockBaseAddress(srcBuf, [])
        let yPlane = CVPixelBufferGetBaseAddressOfPlane(srcBuf, 0)!
            .assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(srcBuf, 0)
        let cPlane = CVPixelBufferGetBaseAddressOfPlane(srcBuf, 1)!
            .assumingMemoryBound(to: UInt8.self)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(srcBuf, 1)
        for row in 0..<h {
            for col in 0..<w {
                yPlane[row * yStride + col] = 180       // E′ = (180−16)/219 ≈ 0.75
            }
        }
        for row in 0..<(h / 2) {
            for col in 0..<(w / 2) {
                cPlane[row * cStride + col] = 128       // neutral chroma
            }
        }
        CVPixelBufferUnlockBaseAddress(srcBuf, [])

        // 8-bit 420v destination — what the SDR writer expects, untagged
        // (render() itself pre-attaches the 709 matrix).
        var dst: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            nil, &dst)
        guard let dstBuf = dst else {
            XCTFail("destination buffer creation failed"); return
        }

        try converter.render(from: srcBuf, to: dstBuf, scheme: .hlg)

        CVPixelBufferLockBaseAddress(dstBuf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(dstBuf, .readOnly) }
        let outPlane = CVPixelBufferGetBaseAddressOfPlane(dstBuf, 0)!
            .assumingMemoryBound(to: UInt8.self)
        let outStride = CVPixelBufferGetBytesPerRowOfPlane(dstBuf, 0)
        for row in stride(from: 0, to: h / 2, by: 8) {
            for col in stride(from: 0, to: w / 2, by: 8) {
                let y = outPlane[row * outStride + col]
                // SDR-encode of the diffuse white: E′709 ≈ 0.997 →
                // limited-range luma ≈ 16 + 219·0.997 ≈ 234.
                XCTAssertGreaterThanOrEqual(y, 230, "diffuse white must land SDR-white")
                XCTAssertLessThanOrEqual(y, 240, "not clipped past white")
            }
        }
    }
}
