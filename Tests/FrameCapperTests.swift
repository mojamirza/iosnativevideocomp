import XCTest
import AVFoundation
@testable import VidCompress

/// The fps-cap slot grid (FrameCapper): the first accepted frame opens a
/// slot one period wide; frames inside the open slot are DROPPED (with a
/// quarter-period tolerance at the edge to absorb timestamp jitter just
/// above the cap); lag beyond a full period re-anchors the grid so VFR
/// bursts stay capped. Every cadence the engine relies on.
final class FrameCapperTests: XCTestCase {

    private let cap = 30

    private var period: CMTime { CMTime(value: 1, timescale: CMTimeScale(cap)) }
    private var tol: CMTime { CMTime(value: 1, timescale: CMTimeScale(cap * 4)) }

    func testFirstFrameAlwaysKept() {
        var c = FrameCapper(cap: cap)
        XCTAssertTrue(c.shouldKeep(CMTime(value: 123, timescale: 600)))
    }

    func testFrameInsideOpenSlotIsDropped() {
        var c = FrameCapper(cap: cap)
        XCTAssertTrue(c.shouldKeep(CMTime(value: 0, timescale: 600)))
        // Half a period later (0.0166… s): strictly inside the open slot.
        XCTAssertFalse(c.shouldKeep(CMTime(value: 1, timescale: 60)))
    }

    func testFrameAtSlotStartIsKeptAndAdvancesGrid() {
        var c = FrameCapper(cap: cap)
        XCTAssertTrue(c.shouldKeep(CMTime(value: 0, timescale: 600)))
        // Exactly one period later — the slot boundary itself.
        XCTAssertTrue(c.shouldKeep(CMTime(value: 1, timescale: 30)))
        // Next half-period frame again falls inside the NEW slot.
        XCTAssertFalse(c.shouldKeep(CMTime(value: 3, timescale: 60)))
    }

    func testConstantHigherFPSHalvesThroughTheCap() {
        // 60 fps into a 30 cap: exactly every other frame survives.
        var c = FrameCapper(cap: cap)
        var kept = 0
        for k in 0..<60 {
            if c.shouldKeep(CMTime(value: CMTimeValue(k), timescale: 60)) { kept += 1 }
        }
        XCTAssertEqual(kept, 30)
    }

    func testToleranceEdgeAbsorbsJitterJustAboveTheCap() {
        var c = FrameCapper(cap: cap)
        XCTAssertTrue(c.shouldKeep(CMTime(value: 0, timescale: 600)))
        // Just BELOW (slot − tol): still inside the slot → dropped.
        let boundary = CMTimeSubtract(CMTimeAdd(CMTime.zero, period), tol)
        let inside = CMTimeSubtract(boundary, CMTime(value: 1, timescale: 6000))
        XCTAssertFalse(c.shouldKeep(inside))
        // Just ABOVE the tolerance edge: a legit frame → kept.
        let outside = CMTimeAdd(boundary, CMTime(value: 1, timescale: 6000))
        XCTAssertTrue(c.shouldKeep(outside))
    }

    func testVFRLagBeyondAPeriodReAnchors() {
        var c = FrameCapper(cap: cap)
        XCTAssertTrue(c.shouldKeep(CMTime(value: 0, timescale: 600)))
        // 1 s later — more than a full period past the open slot: the grid
        // must RE-ANCHOR here (otherwise the following stutter would drop
        // every frame until the stale grid is walked through).
        XCTAssertTrue(c.shouldKeep(CMTime(value: 1, timescale: 1)))
        // And a frame just after the re-anchor is again inside the slot.
        XCTAssertFalse(c.shouldKeep(CMTime(value: 1005, timescale: 1000)))
    }

    func testSingleFPSCapWorks() {
        var c = FrameCapper(cap: 1)
        XCTAssertTrue(c.shouldKeep(CMTime(value: 0, timescale: 100)))    // opens slot ending 1.0
        XCTAssertFalse(c.shouldKeep(CMTime(value: 1, timescale: 100)))   // 0.01 s: inside slot
        XCTAssertTrue(c.shouldKeep(CMTime(value: 11, timescale: 10)))    // 1.1 s: kept, slot → 2.1
        XCTAssertFalse(c.shouldKeep(CMTime(value: 12, timescale: 10)))   // 1.2 s: inside new slot
    }
}
