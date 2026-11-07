import XCTest
import SwiftUI
@testable import VidCompress

/// The screen-background token (Color.appScreen) is the app's answer to
/// "AMOLED black fullscreen, gray in Split View": dark mode must resolve
/// to PURE black on every screen — the same black as the video surface —
/// while light mode keeps the standard grouped background so the white
/// inset cards keep their look. These pin both halves of that contract
/// against the underlying dynamic UIColor.
final class AppThemeTests: XCTestCase {

    private func rgb(_ color: UIColor, style: UIUserInterfaceStyle)
        -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let resolved = color.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    func testDarkModeResolvesToPureBlack() {
        let c = rgb(AppTheme.screenColor, style: .dark)
        XCTAssertEqual(c.r, 0, accuracy: 0.001)
        XCTAssertEqual(c.g, 0, accuracy: 0.001)
        XCTAssertEqual(c.b, 0, accuracy: 0.001)
        XCTAssertEqual(c.a, 1, accuracy: 0.001)
    }

    func testDarkModeMatchesTheVideoSurfaceBlack() {
        // The player's video surface is Color.black — the screen background
        // must be indistinguishable from it in dark mode.
        let screen = rgb(AppTheme.screenColor, style: .dark)
        let videoSurface = rgb(UIColor.black, style: .dark)
        XCTAssertEqual(screen.r, videoSurface.r, accuracy: 0.001)
        XCTAssertEqual(screen.g, videoSurface.g, accuracy: 0.001)
        XCTAssertEqual(screen.b, videoSurface.b, accuracy: 0.001)
    }

    func testLightModeKeepsTheGroupedBackground() {
        // Light mode is UNCHANGED: the standard grouped gray the inset
        // cards are designed against.
        let screen = rgb(AppTheme.screenColor, style: .light)
        let grouped = rgb(UIColor.systemGroupedBackground, style: .light)
        XCTAssertEqual(screen.r, grouped.r, accuracy: 0.001)
        XCTAssertEqual(screen.g, grouped.g, accuracy: 0.001)
        XCTAssertEqual(screen.b, grouped.b, accuracy: 0.001)
    }

    func testDarkModeIsNotTheGroupedGray() {
        // The regression this token exists for: systemGroupedBackground is
        // #1C1C1E in dark — visibly gray on an OLED panel. The token must
        // NOT resolve to it in dark mode.
        let screen = rgb(AppTheme.screenColor, style: .dark)
        let grouped = rgb(UIColor.systemGroupedBackground, style: .dark)
        XCTAssertNotEqual(screen.r, grouped.r, accuracy: 0.005)
    }
}
