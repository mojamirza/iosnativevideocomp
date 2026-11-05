import XCTest
import CoreGraphics
@testable import VidCompress

/// The planner's contract with SizeMath: cap-against-source, budget solve,
/// and the no-trap rule for unknown data rates.
final class PlanTests: XCTestCase {

    private func probe(duration: Double = 600,
                       size: CGSize = CGSize(width: 1920, height: 1080),
                       videoDataRate: Double,
                       fileSize: Int64 = 300_000_000) -> ProbeResult {
        ProbeResult(
            duration: duration,
            sourceSize: size,
            nominalFPS: 30,
            codecSubType: "avc1",
            bitDepth: 8,
            preferredTransform: CGAffineTransform.identity,
            isRotated: false,
            tags: ColorTags(primaries: nil, transferFunction: nil, yCbCrMatrix: nil),
            hasAudio: true,
            videoDataRate: videoDataRate,
            audioDataRate: 128_000,
            fileSize: fileSize)
    }

    private func preset(fixedMbps: Double = 8.0,
                        resolution: ResolutionClass = .keep,
                        targetMB: Double? = nil) -> Preset {
        Preset(name: "test", codec: .h264, resolution: resolution,
               fixedBitrateMbps: fixedMbps, audioBitrateKbps: 128,
               targetSizeMB: targetMB)
    }

    // 3. A 3 Mbps source + an 8 Mbps preset: the source ceiling caps the
    //    plan at 95 % of the source's own rate (no free detail), and
    //    `bitrateCapped` reports it so the coordinator can keep the solve
    //    honest during correction passes.
    func testSourceCeilingCapsPreset() {
        let plan = QualitySizeOptimizer.plan(
            preset: preset(), probe: probe(videoDataRate: 3_000_000))
        XCTAssertTrue(plan.bitrateCapped, "3 Mbps source must cap an 8 Mbps preset")
        XCTAssertEqual(Double(plan.videoBitrate), 2_850_000, accuracy: 1,
                       "cap = source rate × 0.95 at keep-resolution")
        XCTAssertEqual(plan.requestedVideoBitrate, 8_000_000)
        XCTAssertTrue(plan.targetFeasible)
        XCTAssertFalse(plan.sdrConvert, "SDR source → conversion off by default")
    }

    // Target-SIZE mode: the plan's bitrate IS SizeMath's solve — one formula,
    // no re-derivation in the planner.
    func testTargetModeUsesSizeMathSolve() {
        let p = preset(fixedMbps: 8.0, targetMB: 100)
        let plan = QualitySizeOptimizer.plan(
            preset: p, probe: probe(videoDataRate: 50_000_000))
        let expected = SizeMath.videoBitrate(
            targetMB: 100, audioBitrate: plan.audioBitrate, duration: 600)
        XCTAssertEqual(plan.videoBitrate, expected,
                       "planner must not re-derive the budget")
        XCTAssertNotNil(plan.targetBytes)
        XCTAssertTrue(plan.targetFeasible)
        // A 50 Mbps source's ceiling (47.5 Mbps) sits above the ~1.12 Mbps
        // solve — the SOLVE, not the source cap, sets the rate here.
        XCTAssertFalse(plan.bitrateCapped)
        // And when the source ceiling is BELOW the solve, the cap kicks in
        // again (the encode never inflates past what the pixels can use).
        let lean = QualitySizeOptimizer.plan(
            preset: p, probe: probe(videoDataRate: 1_000_000))
        XCTAssertTrue(lean.bitrateCapped)
        XCTAssertLessThanOrEqual(Double(lean.videoBitrate),
                                 Double(SizeMath.videoBitrate(
                                     targetMB: 100, audioBitrate: lean.audioBitrate,
                                     duration: 600)),
                                 "capped plan never exceeds the budget solve")
    }

    // 4. Zero-bitrate (unknown data-rate) source: the ceiling is INFINITY —
    //    Int(infinity) TRAPS, so the planner must apply the ceiling only
    //    when finite. No crash, bad-solve guard intact.
    func testUnknownDataRateDoesNotTrap() {
        let plan = QualitySizeOptimizer.plan(
            preset: preset(), probe: probe(videoDataRate: 0))
        XCTAssertFalse(plan.bitrateCapped)
        XCTAssertEqual(plan.videoBitrate, 8_000_000,
                       "uncapped fixed-bitrate: the preset rate plans as-is")
        // The rationale must still read cleanly (no "inf"/nan garble).
        XCTAssertFalse(plan.rationale.contains("inf"))
    }
}
