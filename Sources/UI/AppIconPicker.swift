import SwiftUI
import UIKit

/// APP ICON PICKER — alternate-icons plumbing plus the About & Settings
/// section. Every variant ships as a LAYERED Icon Composer `.icon` (the
/// user-authored packages, wired as target RESOURCES in Icons/ — the
/// IceCubesApp/Meshtastic pattern; iPadOS 26
/// applies the dark / tinted / clear Home Screen appearances to them
/// AUTOMATICALLY — no per-appearance switching code exists or is needed.
/// The picker's remaining job is choosing the COLOR variant (the
/// system-side automatic switch can't know you'd rather look at sunset
/// than ocean); the system still confirms every manual swap with its own
/// unsuppressible alert, which the picker never tries to hide.
enum AppIconCatalog {
    struct Choice: Identifiable {
        /// The asset-catalog icon set name; `nil` = the primary icon.
        let id: String?
        let name: String
        /// Small preview image set (app icon sets are compiled into
        /// Assets.car and NOT loadable as UIImages).
        let thumb: String
        /// Styled for dark Home Screens.
        let dark: Bool
    }

    static let choices: [Choice] = [
        Choice(id: nil,                  name: "Ocean",    thumb: "IconThumb-Ocean",    dark: false),
        Choice(id: "AppIcon-Sky",        name: "Sky",      thumb: "IconThumb-Sky",      dark: false),
        Choice(id: "AppIcon-Snow",       name: "Snow",     thumb: "IconThumb-Snow",     dark: false),
        Choice(id: "AppIcon-Sunset",     name: "Sunset",   thumb: "IconThumb-Sunset",   dark: false),
        Choice(id: "AppIcon-Violet",     name: "Violet",   thumb: "IconThumb-Violet",   dark: false),
        Choice(id: "AppIcon-Emerald",    name: "Emerald",  thumb: "IconThumb-Emerald",  dark: false),
        Choice(id: "AppIcon-Midnight",   name: "Midnight", thumb: "IconThumb-Midnight", dark: true),
        Choice(id: "AppIcon-Graphite",   name: "Graphite", thumb: "IconThumb-Graphite", dark: true),
    ]

    /// The icon iPadOS currently shows (nil = the primary icon).
    static var currentID: String? { UIApplication.shared.alternateIconName }

    /// Swap the Home Screen icon. The system's own confirmation alert
    /// follows; the async call completes once the swap is accepted.
    static func apply(_ choice: Choice) async throws {
        try await UIApplication.shared.setAlternateIconName(choice.id)
    }
}

/// The About & Settings "App icon" section body: an adaptive card grid
/// with live previews and the current selection marked. Errors bubble to
/// the HOST SHEET's list-level alert — alerts presented from inside list
/// content do not anchor reliably on iPadOS 26 (the same lesson the
/// destructive confirms learned in v1.7.1).
struct AppIconPickerSection: View {
    @Binding var failureText: String?
    /// Mirror of the system's current icon; refreshed on appear (the
    /// system alert may have completed a swap after the last apply) and
    /// after every apply.
    @State private var current = AppIconCatalog.currentID
    @State private var applyingID: String?

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 14)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(AppIconCatalog.choices) { choice in
                Button {
                    guard applyingID == nil, choice.id != current else { return }
                    applyingID = choice.id
                    Task {
                        do {
                            try await AppIconCatalog.apply(choice)
                            current = AppIconCatalog.currentID
                        } catch {
                            failureText = error.localizedDescription
                        }
                        applyingID = nil
                    }
                } label: {
                    card(choice)
                }
                .buttonStyle(.plain)
                .disabled(applyingID != nil)
            }
        }
        .padding(.vertical, 2)
        .onAppear { current = AppIconCatalog.currentID }
    }

    private func card(_ choice: AppIconCatalog.Choice) -> some View {
        let selected = choice.id == current
        return VStack(spacing: 6) {
            Image(choice.thumb)
                .resizable()
                .interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        // Accent badge instead of a bare symbol: a plain
                        // white checkmark vanishes on light thumbs (Snow).
                        ZStack {
                            Circle().fill(Color.accentColor)
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 18, height: 18)
                        .offset(x: 5, y: -5)
                    }
                }
                .opacity(applyingID != nil && applyingID != choice.id ? 0.45 : 1)
                .frame(width: 64, height: 64)
            Text(choice.name)
                .font(.caption2)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .lineLimit(1)
        }
        .accessibilityLabel("App icon \(choice.name)")
        .accessibilityHint(choice.dark ? "Styled for dark mode" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
