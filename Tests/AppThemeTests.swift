import XCTest
import SwiftUI
@testable import VidCompress

/// The app palette (Color.appScreen / .appCard / .appTile) is pinned to
/// explicit component values so it CANNOT re-resolve between windowing
/// modes: Apple's dynamic dark colors have base AND elevated shades
/// (systemBackground #000000 base → #1C1C1E elevated), and an iPad window
/// resolves the ELEVATED level in Split View / Stage Manager / windowed
/// mode — that switch was the "superdark fullscreen, gray Split View" bug.
/// These tests pin every token at BOTH trait levels for both styles.
final class AppThemeTests: XCTestCase {

    private func rgb(_ color: UIColor, style: UIUserInterfaceStyle,
                     level: UIUserInterfaceLevel = .base)
        -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: style),
            UITraitCollection(userInterfaceLevel: level),
        ])
        let resolved = color.resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    private func assertColor(_ c: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat),
                             equals expected: (CGFloat, CGFloat, CGFloat),
                             accuracy: CGFloat = 0.002,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.r, expected.0, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(c.g, expected.1, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(c.b, expected.2, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(c.a, 1, accuracy: accuracy, file: file, line: line)
    }

    // MARK: screen canvas

    func testDarkModeResolvesToPureBlack() {
        assertColor(rgb(AppTheme.screenColor, style: .dark), equals: (0, 0, 0))
    }

    func testDarkModeStaysPureBlackWhenElevated() {
        // THE regression: Split View / Stage Manager windows resolve the
        // elevated level; systemBackground would go #1C1C1E there. The
        // pinned token must not.
        assertColor(rgb(AppTheme.screenColor, style: .dark, level: .elevated),
                    equals: (0, 0, 0))
    }

    func testDarkModeMatchesTheVideoSurfaceBlack() {
        // The player's video surface is Color.black — the screen background
        // must be indistinguishable from it in dark mode, at both levels.
        for level in [UIUserInterfaceLevel.base, .elevated] {
            let screen = rgb(AppTheme.screenColor, style: .dark, level: level)
            let videoSurface = rgb(UIColor.black, style: .dark, level: level)
            XCTAssertEqual(screen.r, videoSurface.r, accuracy: 0.001)
            XCTAssertEqual(screen.g, videoSurface.g, accuracy: 0.001)
            XCTAssertEqual(screen.b, videoSurface.b, accuracy: 0.001)
        }
    }

    func testLightModeKeepsTheGroupedBackground() {
        // Light mode is unchanged: the standard grouped gray (#F2F2F7) the
        // inset cards are designed against — pinned, not dynamic.
        assertColor(rgb(AppTheme.screenColor, style: .light), equals: (242 / 255, 242 / 255, 247 / 255))
        assertColor(rgb(AppTheme.screenColor, style: .light, level: .elevated),
                    equals: (242 / 255, 242 / 255, 247 / 255))
    }

    // MARK: card + tile surfaces

    func testCardSurfaceIsPinnedAtBothLevels() {
        // Dark #1C1C1E (the BASE secondarySystemGroupedBackground the UI was
        // designed against) — never the elevated #2C2C2E. Light: white.
        assertColor(rgb(AppTheme.cardColor, style: .dark), equals: (28 / 255, 28 / 255, 30 / 255))
        assertColor(rgb(AppTheme.cardColor, style: .dark, level: .elevated),
                    equals: (28 / 255, 28 / 255, 30 / 255))
        assertColor(rgb(AppTheme.cardColor, style: .light), equals: (1, 1, 1))
        assertColor(rgb(AppTheme.cardColor, style: .light, level: .elevated), equals: (1, 1, 1))
    }

    func testTileSurfaceIsPinnedAtBothLevels() {
        // Dark #2C2C2E (base tertiarySystemGroupedBackground); light #F2F2F7.
        assertColor(rgb(AppTheme.tileColor, style: .dark), equals: (44 / 255, 44 / 255, 46 / 255))
        assertColor(rgb(AppTheme.tileColor, style: .dark, level: .elevated),
                    equals: (44 / 255, 44 / 255, 46 / 255))
        assertColor(rgb(AppTheme.tileColor, style: .light), equals: (242 / 255, 242 / 255, 247 / 255))
        assertColor(rgb(AppTheme.tileColor, style: .light, level: .elevated),
                    equals: (242 / 255, 242 / 255, 247 / 255))
    }

    // MARK: SwiftUI wrappers — the properties the views ACTUALLY consume

    /// Every view consumes the SwiftUI Color.appScreen/.appCard/.appTile
    /// wrappers; the UIKit tokens pinned above are only their SOURCE. A
    /// wrapper re-pointed at another token — or back at a dynamic system
    /// color, which is the elevation bug's exact shape — previously stayed
    /// green. Color equality compares the underlying provider, so a system
    /// dynamic color can never compare equal to a pinned one.
    func testSwiftUIWrappersMapToTheirPinnedTokens() {
        XCTAssertEqual(Color.appScreen, Color(AppTheme.screenColor))
        XCTAssertEqual(Color.appCard, Color(AppTheme.cardColor))
        XCTAssertEqual(Color.appTile, Color(AppTheme.tileColor))
    }

    /// And through the bridge the views actually render with: round-trip
    /// each wrapper into UIColor and resolve it at BOTH trait levels — the
    /// same component pins the UIKit tokens assert (dark screen stays pure
    /// black when elevated, cards never drift to #2C2C2E, …). A wrapper
    /// that still points at the right token but with a broken provider
    /// (e.g. re-wrapped through a flattening intermediary) fails here.
    func testSwiftUIWrappersResolveToThePinnedComponents() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for level in [UIUserInterfaceLevel.base, .elevated] {
                assertColor(rgb(UIColor(Color.appScreen), style: style, level: level),
                            equals: style == .dark
                                ? (0, 0, 0)
                                : (242 / 255, 242 / 255, 247 / 255))
                assertColor(rgb(UIColor(Color.appCard), style: style, level: level),
                            equals: style == .dark
                                ? (28 / 255, 28 / 255, 30 / 255)
                                : (1, 1, 1))
                assertColor(rgb(UIColor(Color.appTile), style: style, level: level),
                            equals: style == .dark
                                ? (44 / 255, 44 / 255, 46 / 255)
                                : (242 / 255, 242 / 255, 247 / 255))
            }
        }
    }

    // MARK: brand accent

    func testBrandAccentAssetExists() {
        // The AccentColor asset IS the app tint — a missing colorset would
        // silently fall back to system blue (the identity bug this fixes).
        XCTAssertNotNil(UIColor(named: "AccentColor"))
        let ui = UIColor(Color.appAccent)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(a, 1, accuracy: 0.002)
        XCTAssertGreaterThan(b, 0.9, "the brand accent is a blue")
    }
}
