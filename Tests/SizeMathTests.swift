import XCTest
@testable import VidCompress

/// SizeMath is THE single source of truth for the fixed-bitrate ↔ target-size
/// conversion — these are the acceptance cases for that contract.
final class SizeMathTests: XCTestCase {

    // 1. THE canonical case (user acceptance): a 10-minute video, 100 MB
    //    target, 128 kbps audio must solve to ≈ 1.12 Mbps video and an
    //    honest estimate of ≈ 95 MB — overhead-counted, not "≈ 93 MB".
    func testTenMinutes100MBTarget() {
        let solved = SizeMath.videoBitrate(
            targetMB: 100, audioBitrate: 128_000, duration: 600)
        // ≈ 1 119 667 bps; clamp-free happy path.
        XCTAssertEqual(Double(solved), 1.12e6, accuracy: 30_000,
                       "10 min / 100 MB / 128 kbps must solve ≈ 1.12 Mbps")
        XCTAssertEqual(SizeMath.mbpsLabel(solved), "1.12",
                       "two-decimals-under-10-Mbps readout")

        let bytes = SizeMath.expectedBytes(
            videoBitrate: solved, audioBitrate: 128_000, duration: 600)
        XCTAssertEqual(Double(bytes), 95_000_000, accuracy: 2_500_000,
                       "honest estimate ≈ 95 MB (audio + container overhead)")
        // The estimate must also honor the guaranteed budget.
        XCTAssertLessThanOrEqual(Double(bytes), 100_000_000,
                                 "estimate ≤ the guaranteed target")
    }

    // 2. 1 MB on a 1-hour clip is physically impossible — feasibility must
    //    say NO before any encode starts.
    func testInfeasibleOneMegabyteHour() {
        XCTAssertFalse(
            SizeMath.isFeasible(targetMB: 1, audioBitrate: 128_000, duration: 3_600))
        // ... while a realistic clip stays feasible.
        XCTAssertTrue(
            SizeMath.isFeasible(targetMB: 100, audioBitrate: 128_000, duration: 600))
    }

    // 3. Container overhead floor: tiny files are mostly mux/index overhead;
    //    the relative share must never vanish toward zero.
    func testContainerOverheadFloor() {
        XCTAssertEqual(SizeMath.containerOverhead(forBytes: 1_000), 64_000)
        XCTAssertEqual(SizeMath.containerOverhead(forBytes: 0), 64_000)
        // Above ~4.3 MB the 1.5 % share wins the max().
        XCTAssertEqual(SizeMath.containerOverhead(forBytes: 100_000_000), 1_500_000)
    }

    // Degenerate duration: no trap, floor bitrate.
    func testZeroDurationFallsToFloor() {
        XCTAssertEqual(
            SizeMath.videoBitrate(targetMB: 100, audioBitrate: 128_000, duration: 0),
            SizeMath.minVideoBitrate)
    }

    // MARK: deltaLabel — one honest size delta everywhere

    func testDeltaLabelSavings() {
        XCTAssertEqual(SizeMath.deltaLabel(inBytes: 10_000, outBytes: 3_800), "−62%")
    }

    func testDeltaLabelGrowthIsVisible() {
        // Growth must read as a positive delta, never hide behind “−0%”.
        XCTAssertEqual(SizeMath.deltaLabel(inBytes: 10_000, outBytes: 10_800), "+8%")
    }

    func testDeltaLabelSubPercentDeltas() {
        XCTAssertEqual(SizeMath.deltaLabel(inBytes: 10_000, outBytes: 9_980), "−<1%")
        XCTAssertEqual(SizeMath.deltaLabel(inBytes: 10_000, outBytes: 10_020), "+<1%")
        XCTAssertEqual(SizeMath.deltaLabel(inBytes: 10_000, outBytes: 10_000), "−<1%")
    }

    func testDeltaLabelWithoutInput() {
        XCTAssertEqual(SizeMath.deltaLabel(inBytes: 0, outBytes: 500), "—")
        XCTAssertEqual(SizeMath.deltaLabel(inBytes: -1, outBytes: 500), "—")
    }

    // MARK: durationLabel — m:ss / h:mm:ss (never “125:30”)

    func testDurationLabelShort() {
        XCTAssertEqual(SizeMath.durationLabel(0), "0:00")
        XCTAssertEqual(SizeMath.durationLabel(65.4), "1:05")
        XCTAssertEqual(SizeMath.durationLabel(7549.6), "2:05:50")
    }

    func testDurationLabelDegenerate() {
        XCTAssertEqual(SizeMath.durationLabel(-3), "—")
        XCTAssertEqual(SizeMath.durationLabel(Double.nan), "—")
    }
}
