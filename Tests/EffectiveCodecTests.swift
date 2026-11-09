import XCTest
@testable import VidCompress

/// The plan's EFFECTIVE-codec rule (shared with CompressionEngine by the
/// same inputs): H.264 is 8-bit only, so a 10-bit/HDR source silently
/// encodes as HEVC — unless a real SDR conversion re-renders the composition
/// to 8-bit (then H.264 stays legal). File stamps, the record's codecLabel
/// and the setup chips all read this value; a stamp saying H.264 over an
/// HEVC file would make the app and Files disagree.
final class EffectiveCodecTests: XCTestCase {

    private func probe(hdr: Bool = false, bitDepth: Int = 8) -> ProbeResult {
        ProbeResult(
            duration: 600,
            sourceSize: CGSize(width: 1920, height: 1080),
            nominalFPS: 30,
            codecSubType: "avc1",
            bitDepth: bitDepth,
            preferredTransform: CGAffineTransform.identity,
            isRotated: false,
            // HDR transfer tag: HLG (any HLG/PQ transfers → isHDR).
            tags: ColorTags(
                primaries: hdr ? "itu_r_2020" : nil,
                transferFunction: hdr ? "itu_r_2100_hlg" : nil,
                yCbCrMatrix: hdr ? "itu_r_2020" : nil),
            hasAudio: true,
            videoDataRate: 4_000_000,
            audioDataRate: 128_000,
            fileSize: 300_000_000)
    }

    private func preset(codec: VideoCodec, hdrToSDR: Bool = false) -> Preset {
        Preset(name: "t",
               codec: codec,
               resolution: .keep,
               fixedBitrateMbps: 4,
               fpsCap: nil,
               audioBitrateKbps: 128,
               isUserDefined: true,
               targetSizeMB: nil,
               audioChannels: nil,
               // The plan's sdrConvert only ever engages on a REAL HDR probe.
               hdrToSDR: hdrToSDR ? true : nil)
    }

    func testH264OnSDR8BitStaysH264() {
        let p = QualitySizeOptimizer.plan(preset: preset(codec: .h264), probe: probe())
        XCTAssertEqual(p.effectiveCodec, .h264)
        XCTAssertFalse(p.sdrConvert)
    }

    func testH264OnHDRIsUpgradedToHEVC() {
        let p = QualitySizeOptimizer.plan(
            preset: preset(codec: .h264), probe: probe(hdr: true))
        XCTAssertEqual(p.effectiveCodec, .hevc)
    }

    func testH264On10BitSDRIsUpgradedToHEVC() {
        let p = QualitySizeOptimizer.plan(
            preset: preset(codec: .h264), probe: probe(bitDepth: 10))
        XCTAssertEqual(p.effectiveCodec, .hevc)
    }

    func testH264OnHDRWithRealSDRConversionStaysH264() {
        // The composition path re-renders 8-bit 709 — H.264 is legal again.
        let p = QualitySizeOptimizer.plan(
            preset: preset(codec: .h264, hdrToSDR: true),
            probe: probe(hdr: true))
        XCTAssertTrue(p.sdrConvert)
        XCTAssertEqual(p.effectiveCodec, .h264)
    }

    func testHEVCRequestsAreNeverChanged() {
        // HEVC handles 10-bit natively in every case.
        XCTAssertEqual(QualitySizeOptimizer.plan(
            preset: preset(codec: .hevc), probe: probe()).effectiveCodec, .hevc)
        XCTAssertEqual(QualitySizeOptimizer.plan(
            preset: preset(codec: .hevc), probe: probe(hdr: true)).effectiveCodec, .hevc)
        XCTAssertEqual(QualitySizeOptimizer.plan(
            preset: preset(codec: .hevc), probe: probe(bitDepth: 10)).effectiveCodec, .hevc)
    }
}
