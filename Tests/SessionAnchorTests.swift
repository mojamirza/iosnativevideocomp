import XCTest
import AVFoundation
@testable import VidCompress

/// The session-anchor rule EVERY consumer shares: the muxer anchor is the
/// MINIMUM of the track starts, each clamped to ≥ 0 — a track starting at
/// (or below) zero pins the anchor to 0 so no sample can append "before the
/// session". The probe and the engine both call this one function.
final class SessionAnchorTests: XCTestCase {

    private func t(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    func testPositiveAnchorsTakeTheMinimum() {
        XCTAssertEqual(CMTimeGetSeconds(SessionAnchor.start(video: t(1.0), audio: t(0.5))), 0.5, accuracy: 1e-9)
        XCTAssertEqual(CMTimeGetSeconds(SessionAnchor.start(video: t(0.25), audio: t(1.0))), 0.25, accuracy: 1e-9)
        XCTAssertEqual(CMTimeGetSeconds(SessionAnchor.start(video: t(0.3), audio: t(0.9))), 0.3, accuracy: 1e-9)
    }

    func testVideoAtZeroPinsTheAnchor() {
        // The original regression: a video start of 0 read as "no anchor",
        // so the audio's 0.5 became the anchor and PTS-0 video frames fell
        // BEFORE the session. Zero wins.
        XCTAssertEqual(CMTimeGetSeconds(SessionAnchor.start(video: .zero, audio: t(0.5))), 0, accuracy: 1e-9)
    }

    func testNegativeStartsClampToZero() {
        XCTAssertEqual(CMTimeGetSeconds(SessionAnchor.start(video: t(-2), audio: t(0.5))), 0, accuracy: 1e-9)
        XCTAssertEqual(CMTimeGetSeconds(SessionAnchor.start(video: t(-1), audio: t(-1))), 0, accuracy: 1e-9)
        XCTAssertEqual(CMTimeGetSeconds(SessionAnchor.start(video: t(1), audio: t(-0.25))), 0, accuracy: 1e-9)
    }

    func testMissingAudioUsesTheVideoAnchor() {
        XCTAssertEqual(CMTimeGetSeconds(SessionAnchor.start(video: t(1.0), audio: nil)), 1.0, accuracy: 1e-9)
        XCTAssertEqual(CMTimeGetSeconds(SessionAnchor.start(video: .zero, audio: nil)), 0, accuracy: 1e-9)
    }

    func testInvalidTimesAreNeutralized() {
        // Indefinite/infinite timestamps (damaged headers) must not poison
        // the minimum: they are treated as 0.
        let indefinite = CMTime.indefinite
        let nan = CMTime(seconds: .nan, preferredTimescale: 600)
        XCTAssertEqual(CMTimeGetSeconds(SessionAnchor.start(video: indefinite, audio: t(0.5))), 0, accuracy: 1e-9)
        XCTAssertEqual(CMTimeGetSeconds(SessionAnchor.start(video: t(1.0), audio: nan)), 0, accuracy: 1e-9)
        XCTAssertEqual(CMTimeGetSeconds(SessionAnchor.start(video: indefinite, audio: nan)), 0, accuracy: 1e-9)
    }
}
