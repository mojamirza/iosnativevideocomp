import SwiftUI
import UIKit

/// The ONE screen-level background color, shared by every full-screen
/// container in the app (root list, split-view sidebar, setup sheet,
/// integrity report, player, preset editor, settings).
///
/// WHY: `systemGroupedBackground` — the default behind grouped content —
/// is a DARK GRAY (#1C1C1E) in dark mode, not black. Next to the pure
/// black of the video surface the mismatch was plainly visible: the
/// fullscreen player read as AMOLED black while the other screens (and
/// the app's window in Split View) sat on gray. This token pins dark mode
/// to `systemBackground` — TRUE black, AMOLED-friendly — in every
/// windowing mode (fullscreen, Split View, Stage Manager), while light
/// mode keeps the standard grouped gray so the white inset cards keep
/// their look. Card-level surfaces (`secondarySystemGroupedBackground`,
/// #2C2C2E in dark) are unchanged: they still read as elevated on black.
enum AppTheme {
    /// The backing dynamic UIColor (kept as UIColor so it can be resolved
    /// against an explicit trait collection — and unit-tested).
    static let screenColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .systemBackground
            : .systemGroupedBackground
    }
}

extension Color {
    /// SwiftUI face of `AppTheme.screenColor` — use this on every
    /// screen-level `.background(...)`; never `systemGroupedBackground`.
    static var appScreen: Color { Color(AppTheme.screenColor) }
}
