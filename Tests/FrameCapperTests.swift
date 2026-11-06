import XCTest
import AVFoundation
@testable import VidCompress

/// The fps-cap slot-grid cadence, extracted from the video pipe so it can be
/// pinned: first accepted frame opens a slot; frames inside the open slot are
/// dropped (quarter-period jitter tolerance); lag beyond a full period
/// re-anchors so variable-frame-rate bursts stay capped.
final class FrameCapperTests: XCTestCase {

    private func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

    // 30 fps cap → period 1/30 s.
    private func capper(cap: Int = 30) -> FrameCapper { FrameCapper(cap: cap) }

    func testFirstFrameOpensTheSlot() {
        var c = capper()
        XCTAssertTrue(c.shouldKeep(t(0)))
    }

    func testFramesInsideTheOpenSlotAreDropped() {
        var c = capper()
        XCTAssertTrue(c.shouldKeep(t(0)))
        // 1/60 s later: inside the 1/30 slot → dropped.
        XCTAssertFalse(c.shouldKeep(t(1.0 / 60.0)))
    }

    func testNextSlotFrameIsKept() {
        var c = capper()
        XCTAssertTrue(c.shouldKeep(t(0)))
        // Exactly one period later: kept, and the grid advances.
        XCTAssertTrue(c.shouldKeep(t(1.0 / 30.0)))
        XCTAssertFalse(c.shouldKeep(t(1.0 / 30.0 + 1.0 / 120.0)))
        XCTAssertTrue(c.shouldKeep(t(2.0 / 30.0)))
    }

    func testJitterJustAboveTheCapIsTolerated() {
        var c = capper()
        XCTAssertTrue(c.shouldKeep(t(0)))
        // A quarter period BEFORE the next boundary is still kept (sources
        // hovering just above the cap must not hitch).
        XCTAssertTrue(c.shouldKeep(t(1.0 / 30.0 - 1.0 / 120.0)))
    }

    func testVFRGapReanchorsTheGrid() {
        var c = capper()
        XCTAssertTrue(c.shouldKeep(t(0)))
        // A 2-second gap (recording paused): far beyond the slot — kept, and
        // the grid re-anchors here so a follow-up burst is capped again.
        XCTAssertTrue(c.shouldKeep(t(2.0)))
        XCTAssertFalse(c.shouldKeep(t(2.0 + 1.0 / 60.0)))
    }

    func testLateFramesBeyondTheToleranceAreKept() {
        var c = capper()
        XCTAssertTrue(c.shouldKeep(t(0)))
        // Half a period late: outside the tolerance, still kept (the grid
        // advances by one period from the previous anchor).
        XCTAssertTrue(c.shouldKeep(t(1.0 / 30.0 + 1.0 / 60.0)))
    }
}
