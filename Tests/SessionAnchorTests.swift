import XCTest
import AVFoundation
@testable import VidCompress

/// The muxer anchor is shared by the ENGINE and the PROBE — these pin the
/// documented edge cases (a video starting at 0 must anchor at 0 even when
/// audio starts later; trimmed clips anchor at their earliest track start;
/// invalid starts clamp to 0 so no sample can append before the session).
final class SessionAnchorTests: XCTestCase {

    private func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

    // video 0 + audio 0.5 → 0 (the regression that started the helper:
    // a 0 video start is NOT "no video anchor").
    func testVideoZeroAnchorsAtZeroEvenWhenAudioStartsLater() {
        XCTAssertEqual(SessionAnchor.start(video: t(0), audio: t(0.5)), .zero)
    }

    // video 1 + audio 0.5 → 0.5 · video 0.5 + audio 1 → 0.5
    func testTrimmedClipAnchorsAtEarliestStart() {
        XCTAssertEqual(SessionAnchor.start(video: t(1), audio: t(0.5)), t(0.5))
        XCTAssertEqual(SessionAnchor.start(video: t(0.5), audio: t(1)), t(0.5))
    }

    func testVideoOnlyTrimmedClip() {
        XCTAssertEqual(SessionAnchor.start(video: t(1), audio: nil), t(1))
    }

    func testInvalidTimesAnchorAtZero() {
        // Negative/indefinite starts clamp to 0 — no sample may append
        // before the session.
        XCTAssertEqual(SessionAnchor.start(video: t(-2), audio: t(0.5)), .zero)
        XCTAssertEqual(SessionAnchor.start(video: .indefinite, audio: nil), .zero)
        XCTAssertEqual(SessionAnchor.start(video: t(0), audio: .indefinite), .zero)
    }
}
