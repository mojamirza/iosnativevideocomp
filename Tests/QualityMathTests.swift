import XCTest
@testable import VidCompress

/// Pure-math contract of the quality scorer (PSNR / SSIM). The decode/
/// compare plumbing is exercised on-device via the report; these pin the
/// numbers the report language is calibrated against.
final class QualityMathTests: XCTestCase {

    private func frame(_ pixels: [UInt8], w: Int, h: Int) -> QualityCheck.LumaFrame {
        QualityCheck.LumaFrame(luma: pixels, width: w, height: h)
    }

    // Identical frames: PSNR hits the 99.0 "no error" stand-in; SSIM is 1.0.
    func testIdenticalFrames() {
        let f = frame(Array(repeating: 128, count: 320 * 180), w: 320, h: 180)
        XCTAssertEqual(QualityCheck.psnr(f, f), 99.0)
        XCTAssertEqual(QualityCheck.ssim(f, f) ?? 0, 1.0, accuracy: 1e-9)
    }

    // One level step on a single pixel: mse = 1 → the dB number every
    // reference formula gives for a ±1 8-bit error.
    func testOneLevelStepPSNR() {
        let a = frame([255], w: 1, h: 1)
        let b = frame([254], w: 1, h: 1)
        let p = QualityCheck.psnr(a, b)
        // 10·log10(255²/1) = 48.13 dB
        XCTAssertEqual(p ?? 0, 48.1308, accuracy: 0.05)
    }

    // A degraded copy must score strictly between the bounds.
    func testDegradesBelowIdentical() {
        var pixels = [UInt8](repeating: 100, count: 320 * 180)
        let orig = frame(pixels, w: 320, h: 180)
        // Blocky compression artifact: alternate bands ±10.
        for i in pixels.indices where (i / 40) % 2 == 0 { pixels[i] = 110 }
        let deg = frame(pixels, w: 320, h: 180)
        let p = QualityCheck.psnr(orig, deg) ?? -1
        let s = QualityCheck.ssim(orig, deg) ?? -1
        XCTAssertGreaterThan(p, 0)
        XCTAssertLessThan(p, 99.0)
        XCTAssertGreaterThan(s, 0)
        XCTAssertLessThanOrEqual(s, 1.0)
        XCTAssertLessThan(s, 1.0, "a visibly degraded copy is not SSIM 1.0")
        // And the grade bands hold: a mild ±10 artifact lands "acceptable".
        let g = QualityCheck.grade(psnr: p, ssim: s)
        XCTAssertEqual(g.severity, .warn, "±10 banding must not grade pass")
    }

    // Mismatched geometry can't lie — the scorer refuses to compare.
    func testRefusesMismatchedSizes() {
        let a = frame(Array(repeating: 10, count: 4), w: 2, h: 2)
        let b = frame(Array(repeating: 10, count: 4), w: 4, h: 1)
        XCTAssertNil(QualityCheck.psnr(a, b))
        XCTAssertNil(QualityCheck.ssim(a, b))
    }

    // Grade band boundaries (the report language contract).
    func testGradeBands() {
        XCTAssertEqual(QualityCheck.grade(psnr: 45, ssim: 0.999).severity, .pass)
        XCTAssertEqual(QualityCheck.grade(psnr: 36, ssim: 0.95).severity, .pass)
        XCTAssertEqual(QualityCheck.grade(psnr: 25, ssim: 0.8).severity, .warn)
        XCTAssertEqual(QualityCheck.grade(psnr: 15, ssim: 0.4).severity, .warn,
                       "weak scores still warn — never fail silently on quality")
    }
}
