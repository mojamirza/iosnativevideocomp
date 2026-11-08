import SwiftUI
import UIKit

/// The screen-level palette shared by every full-screen container in the app
/// (root list, split-view sidebar, setup sheet, integrity report, player,
/// preset editor, settings) plus the card surfaces that sit on it.
///
/// WHY EXPLICIT COMPONENTS INSTEAD OF SEMANTIC SYSTEM COLORS:
/// Apple's dynamic dark-mode colors have TWO shades each — a BASE one and an
/// ELEVATED one. `systemBackground` is #000000 at base but #1C1C1E when the
/// window resolves `userInterfaceLevel == .elevated`, which is exactly what an
/// iPad window gets in Split View / Stage Manager / windowed mode. The same
/// applies to the grouped card surfaces (`secondarySystemGroupedBackground`
/// #1C1C1E → #2C2C2E, `tertiarySystemGroupedBackground` #2C2C2E → lighter).
/// Result: the fullscreen app read as AMOLED black while Split View brightened
/// the canvas to gray and every card with it. Pinning literal RGBA values per
/// style makes the palette PROVABLY identical in every windowing mode — the
/// resolution can no longer depend on any trait other than dark/light.
///
/// Values (unchanged from the system defaults the UI was designed against):
///  · screen  dark #000000 (true black, AMOLED-friendly, == the video
///            surface) · light #F2F2F7 (the standard grouped gray so the
///            white inset cards keep their look)
///  · card    dark #1C1C1E · light #FFFFFF (was secondarySystemGroupedBackground)
///  · tile    dark #2C2C2E · light #F2F2F7 (was tertiarySystemGroupedBackground)
enum AppTheme {

    // Screen canvas
    static let screenColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? Self.black : Self.groupedGrayLight
    }
    // Card surface (inset cards, queue status bar, report items, preset rows)
    static let cardColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? Self.cardDark : Self.white
    }
    // Inner tile surface (probe grid cells)
    static let tileColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? Self.tileDark : Self.groupedGrayLight
    }

    // Pinned components — no dynamic lookup, nothing left to re-resolve.
    static let black = UIColor(red: 0, green: 0, blue: 0, alpha: 1)
    static let white = UIColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let groupedGrayLight = UIColor(red: 242 / 255.0, green: 242 / 255.0,
                                          blue: 247 / 255.0, alpha: 1)
    static let cardDark = UIColor(red: 28 / 255.0, green: 28 / 255.0,
                                  blue: 30 / 255.0, alpha: 1)   // #1C1C1E
    static let tileDark = UIColor(red: 44 / 255.0, green: 44 / 255.0,
                                  blue: 46 / 255.0, alpha: 1)   // #2C2C2E

    // HIG METRICS — the recurring radii of the design system, in one place
    // so rows, thumbnails and tiles can never drift apart again.
    /// Video thumbnails (Files/TV use tight, squircle-adjacent corners).
    static let thumbRadius: CGFloat = 6
    /// Inner tiles (probe grid cells).
    static let tileRadius: CGFloat = 10
    /// Medium cards (report items, banners).
    static let cardRadius: CGFloat = 12
    /// Large surface cards (setup sheet, report summary).
    static let largeCardRadius: CGFloat = 16
}

extension Color {
    /// SwiftUI face of `AppTheme.screenColor` — use this on every
    /// screen-level `.background(...)`; never a dynamic system background.
    static var appScreen: Color { Color(AppTheme.screenColor) }
    /// Elevation-invariant card surface — replaces
    /// `Color(.secondarySystemGroupedBackground)` everywhere a card is drawn.
    static var appCard: Color { Color(AppTheme.cardColor) }
    /// Elevation-invariant inner tile — replaces
    /// `Color(.tertiarySystemGroupedBackground)`.
    static var appTile: Color { Color(AppTheme.tileColor) }
}
