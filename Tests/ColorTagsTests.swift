import XCTest
import AVFoundation
@testable import VidCompress

/// The color-tag contract. The SDR conversion path (an AVFoundation video
/// composition declared Rec.709) leans on three things that must never
/// drift: HDR detection, the resolved-tag completeness (never a partial
/// dictionary — the writer misbehaves on those), and the shared neutral SDR
/// triplet resolution that the engine and the verifier both use.
final class ColorTagsTests: XCTestCase {

    private func tags(_ pri: String?, _ tf: String?, _ mat: String?) -> ColorTags {
        ColorTags(primaries: pri, transferFunction: tf, yCbCrMatrix: mat)
    }

    func testHDRDetection() {
        XCTAssertTrue(tags("ITU_R_2020", "itu_r_2100_hlg", "ITU_R_2020").isHDR)
        XCTAssertTrue(tags(nil, "smpte_st_2084_pq", nil).isHDR)
        XCTAssertTrue(tags(nil, "pq", nil).isHDR)
        XCTAssertTrue(tags(nil, "smpte2084", nil).isHDR)
        XCTAssertFalse(tags("ITU_R_709_2", "itu_r_709_2", "ITU_R_709_2").isHDR)
        XCTAssertFalse(tags(nil, nil, nil).isHDR)
    }

    /// Empty tags always resolve to a COMPLETE SDR triplet — this is the
    /// exact call the engine makes for a conversion's writer settings and
    /// buffer attachments (nil-empty tags ⇒ "carried nothing" ⇒ canonical
    /// defaults). SD classification routes the MATRIX to 601, everything
    /// else stays 709.
    func testNeutralResolution() {
        let empty = ColorTags(primaries: nil, transferFunction: nil, yCbCrMatrix: nil)
        let want = empty.resolved(isHDR: false, sd: false)
        XCTAssertEqual(want.primaries, "ITU_R_709_2")
        XCTAssertEqual(want.transferFunction, "ITU_R_709_2")
        XCTAssertEqual(want.yCbCrMatrix, "ITU_R_709_2")
        let sd = empty.resolved(isHDR: false, sd: true)
        XCTAssertEqual(sd.yCbCrMatrix, "ITU_R_601_4")
        XCTAssertEqual(sd.transferFunction, "ITU_R_709_2")
        XCTAssertEqual(sd.primaries, "ITU_R_709_2")
    }

    /// The resolved triplet maps onto real AVFoundation constants via
    /// writerColorProperties — and that dictionary is always COMPLETE (all
    /// three keys), because a partial color dictionary is undefined
    /// behavior in AVAssetWriter.
    func testWriterColorPropertiesComplete() {
        let empty = ColorTags(primaries: nil, transferFunction: nil, yCbCrMatrix: nil)
        let props = empty.writerColorProperties(sd: false)
        XCTAssertNotNil(props[AVVideoColorPrimariesKey])
        XCTAssertNotNil(props[AVVideoTransferFunctionKey])
        XCTAssertNotNil(props[AVVideoYCbCrMatrixKey])
        XCTAssertEqual(props.count, 3)
        // HDR source: transfer stays HLG, matrix 2020 (preserved, never
        // relabeled — the color pillar).
        let hlg = ColorTags(primaries: nil, transferFunction: "itu_r_2100_hlg",
                            yCbCrMatrix: "ITU_R_2020")
        let hp = hlg.writerColorProperties(sd: false)
        XCTAssertEqual(hp[AVVideoTransferFunctionKey] as? String,
                       AVVideoTransferFunction_ITU_R_2100_HLG)
        XCTAssertEqual(hp[AVVideoYCbCrMatrixKey] as? String,
                       AVVideoYCbCrMatrix_ITU_R_2020)
    }
}
