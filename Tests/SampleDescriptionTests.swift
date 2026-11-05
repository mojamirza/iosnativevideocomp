import XCTest
import AVFoundation
@testable import VidCompress

/// Byte-level contract of the sample-description depth parser: HEVC reads
/// bitDepthLumaMinus8 out of hvcC byte 17 (minus8 == 0 is plain 8-bit and
/// MUST be reported); AVC maps Hi10P profiles to 10 and everything else to
/// 8. The verifier's HDR/depth checks depend on this parsing.
final class SampleDescriptionTests: XCTestCase {

    /// Fabricates a video format description carrying the given sample
    /// description extension atoms (the same channel the parser reads).
    private func makeFormat(codecType: FourCharCode, atoms: [String: Any]) -> CMFormatDescription? {
        var out: CMFormatDescription?
        let ext = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: atoms] as CFDictionary
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: 1920, height: 1080,
            extensions: ext,
            formatDescriptionOut: &out)
        return status == noErr ? out : nil
    }

    private func hvcCAtom(minus8: Int, count: Int = 24) -> Data {
        var d = Data(repeating: 0, count: count)
        if count > 17 { d[17] = UInt8(minus8 & 0xFF) }
        return d
    }

    func testHEVCTenBit() throws {
        let fmt = try XCTUnwrap(makeFormat(
            codecType: kCMVideoCodecType_HEVC,
            atoms: ["hvcC": hvcCAtom(minus8: 2)]))
        XCTAssertEqual(SampleDescription.depth(of: fmt), 10)
    }

    // minus8 == 0 is plain Main (8-bit) — it MUST be reported, not nil:
    // the verifier's "HDR source flattened to 8-bit" case depends on it.
    func testHEVCEightBit() throws {
        let fmt = try XCTUnwrap(makeFormat(
            codecType: kCMVideoCodecType_HEVC,
            atoms: ["hvcC": hvcCAtom(minus8: 0)]))
        XCTAssertEqual(SampleDescription.depth(of: fmt), 8)
    }

    func testHEVCInvalidMinus8ReturnsNil() throws {
        let fmt = try XCTUnwrap(makeFormat(
            codecType: kCMVideoCodecType_HEVC,
            atoms: ["hvcC": hvcCAtom(minus8: 5)]))
        XCTAssertNil(SampleDescription.depth(of: fmt))
    }

    func testHvcCTooShortReturnsNil() throws {
        let fmt = try XCTUnwrap(makeFormat(
            codecType: kCMVideoCodecType_HEVC,
            atoms: ["hvcC": hvcCAtom(minus8: 2, count: 10)]))
        XCTAssertNil(SampleDescription.depth(of: fmt))
    }

    func testAVCHiTenProfileIsTenBit() throws {
        var avcC = Data(repeating: 0, count: 8)
        avcC[1] = 110   // profile_idc 110 = Hi10P
        let fmt = try XCTUnwrap(makeFormat(
            codecType: kCMVideoCodecType_H264,
            atoms: ["avcC": avcC]))
        XCTAssertEqual(SampleDescription.depth(of: fmt), 10)
    }

    func testAVCMainProfileIsEightBit() throws {
        var avcC = Data(repeating: 0, count: 8)
        avcC[1] = 66    // profile_idc 66 = Baseline
        let fmt = try XCTUnwrap(makeFormat(
            codecType: kCMVideoCodecType_H264,
            atoms: ["avcC": avcC]))
        XCTAssertEqual(SampleDescription.depth(of: fmt), 8)
    }

    func testNoAtomsReturnsNil() throws {
        let fmt = try XCTUnwrap(makeFormat(codecType: kCMVideoCodecType_HEVC, atoms: [:]))
        XCTAssertNil(SampleDescription.depth(of: fmt))
    }
}
