import XCTest
import AVFoundation
@testable import VidCompress

/// The trim helper's contract (TrimMath): the window predicate and the
/// applied probe. These pin the ORIGINAL bugs — an end-only cut must count
/// (the old start() compared trimEnd against trimEnd−trimStart, which for
/// trimStart == 0 is never true), a window must be ≥ 0.5 s, and the applied
/// probe must scale fileSize proportionally (the −X% story, the target-size
/// solve and the report's inBytes all describe the trimmed video).
final class TrimMathTests: XCTestCase {

    private func probe(dur: Double, bytes: Int64 = 1_000_000) -> ProbeResult {
        ProbeResult(
            duration: dur,
            sourceSize: CGSize(width: 1920, height: 1080),
            nominalFPS: 30,
            codecSubType: "avc1",
            bitDepth: 8,
            preferredTransform: CGAffineTransform.identity,
            isRotated: false,
            tags: ColorTags(primaries: nil, transferFunction: nil, yCbCrMatrix: nil),
            hasAudio: true,
            videoDataRate: 3_000_000,
            audioDataRate: 128_000,
            fileSize: bytes)
    }

    func testNoTrimReturnsProbeUnchanged() {
        let p = probe(dur: 100, bytes: 5_000_000)
        let out = TrimMath.apply(p, start: 0, end: 100)
        XCTAssertEqual(out.duration, p.duration)
        XCTAssertEqual(out.fileSize, p.fileSize)
        XCTAssertFalse(TrimMath.isTrimmed(start: 0, end: 100, duration: 100))
    }

    func testEndOnlyTrimCounts() {
        // The headline case: trimStart == 0, end cut to 60% of the source.
        XCTAssertTrue(TrimMath.isTrimmed(start: 0, end: 60, duration: 100))
        let out = TrimMath.apply(probe(dur: 100, bytes: 10_000_000), start: 0, end: 60)
        XCTAssertEqual(out.duration, 60, accuracy: 1e-9)
        XCTAssertEqual(out.fileSize, Int64(10_000_000.0 * 60.0 / 100.0))
    }

    func testStartOnlyTrimCounts() {
        XCTAssertTrue(TrimMath.isTrimmed(start: 30, end: 100, duration: 100))
        let out = TrimMath.apply(probe(dur: 100, bytes: 8_000_000), start: 30, end: 100)
        XCTAssertEqual(out.duration, 70, accuracy: 1e-9)
        XCTAssertEqual(out.fileSize, Int64(8_000_000.0 * 70.0 / 100.0))
    }

    func testSubHalfSecondWindowIsNotATrim() {
        XCTAssertFalse(TrimMath.isTrimmed(start: 0, end: 0.49, duration: 10))
        XCTAssertFalse(TrimMath.isTrimmed(start: 5, end: 5.4999, duration: 10))
        // Exactly 0.5 s IS a valid window.
        XCTAssertTrue(TrimMath.isTrimmed(start: 5, end: 5.5, duration: 10))
    }

    func testHalfSecondSliverAtExtremesIsNotATrim() {
        // 0.05 s epsilon: a window that removes nothing REAL (start 0.03,
        // end duration−0.03) must not count — otherwise every source gets a
        // pointless "trimmed" plan.
        XCTAssertFalse(TrimMath.isTrimmed(start: 0.03, end: 100, duration: 100))
        XCTAssertFalse(TrimMath.isTrimmed(start: 0, end: 99.97, duration: 100))
        // Just past epsilon it counts.
        XCTAssertTrue(TrimMath.isTrimmed(start: 0.06, end: 100, duration: 100))
        XCTAssertTrue(TrimMath.isTrimmed(start: 0, end: 99.9, duration: 100))
    }

    func testProportionalFileSizeIsMonotonicInWindowLength() {
        let full = probe(dur: 200, bytes: 8_000_000)
        let ten = TrimMath.apply(full, start: 0, end: 10)
        let fifty = TrimMath.apply(full, start: 0, end: 50)
        XCTAssertLessThan(ten.fileSize, fifty.fileSize)
        XCTAssertLessThan(fifty.fileSize, full.fileSize)
        XCTAssertEqual(Double(fifty.fileSize),
                       Double(ten.fileSize) * 5.0, accuracy: Double(ten.fileSize) * 0.001)
    }

    func testZeroDurationSourcePassesThroughUntouched() {
        // Degenerate probe: isTrimmed is false for ANY window here (a 0.5 s
        // window cannot cut real content from a zero-length video), so
        // apply() returns the probe AS-IS — the file-size math is never
        // reached and must not divide.
        let p = probe(dur: 0, bytes: 100)
        let out = TrimMath.apply(p, start: 0, end: 0)
        XCTAssertEqual(out.duration, 0)
        XCTAssertEqual(out.fileSize, 100)
        XCTAssertEqual(out.duration, p.duration)
        XCTAssertEqual(out.fileSize, p.fileSize)
    }

    func testSubTenthSecondSourceReachesTheGuard() {
        // The max(·, 0.1) guard only bites when a trim window is VALID on a
        // probe shorter than 0.1 s — start > 0.05 with an end past the
        // (degenerate) duration satisfies isTrimmed. Without the guard the
        // scale would divide by 0.05 and INFLATE the size; with it the
        // divisor floors at 0.1.
        let p = probe(dur: 0.05, bytes: 100)
        XCTAssertTrue(TrimMath.isTrimmed(start: 0.06, end: 0.6, duration: 0.05))
        let out = TrimMath.apply(p, start: 0.06, end: 0.6)
        XCTAssertEqual(out.duration, 0.54, accuracy: 1e-9)
        XCTAssertEqual(Double(out.fileSize), 540, accuracy: 1)
    }
}
