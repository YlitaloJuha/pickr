import SwiftUI

/// Spacing, corner radii, sizes and semantic colours shared by every screen (§3.3, §6.3 WP5).
///
/// Everything here is solid content. Cards, tiles, photos, list rows and banners are never
/// glass (§3.2 rule 1); the floating control layer gets its glass from the system.
nonisolated enum Theme {
    /// The spacing scale. Use these instead of literal padding values.
    nonisolated enum Spacing {
        static let extraSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        /// Inside a moment card or an inline banner (§3.3 S3).
        static let cardPadding: CGFloat = 14
    }

    /// Corner radii. Every rounded shape uses continuous corners.
    nonisolated enum Radius {
        /// Moment cards and inline banners.
        static let card: CGFloat = 16
        /// Grid tiles.
        static let tile: CGFloat = 8
        /// The small thumbnails in a card's strip.
        static let thumbnail: CGFloat = 6
    }

    /// Fixed sizes for photo content. Text never gets a fixed size: it follows Dynamic Type.
    nonisolated enum Size {
        /// One thumbnail in a moment card's strip.
        static let stripThumbnail: CGFloat = 48
        /// The gap between strip thumbnails (ADAPTIVE.md §6.3).
        static let stripSpacing: CGFloat = 6
        /// The most tiles a card's strip shows (thumbnails plus the "+N" tile). Narrower
        /// cards show fewer, down to 3 (`StripLayout`).
        static let stripMaximumTiles = 6
        /// The most strip tiles at accessibility text sizes.
        static let stripMaximumTilesAccessibility = 4
        /// The gap between grid tiles, both ways. Columns come from the grid's width
        /// (`PhotoGridLayout`, ADAPTIVE.md §6.1).
        static let gridSpacing: CGFloat = 4
        /// The accent border on a kept tile.
        static let keptBorder: CGFloat = 3
    }

    /// Insets for rows of cards in a plain `List`.
    nonisolated enum Insets {
        /// 6 pt above and below, 16 pt at the sides (§3.3 S3).
        static let cardRow = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
    }

    /// The rounded shapes, with continuous corners.
    nonisolated enum Shapes {
        static let card = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        static let tile = RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
        static let thumbnail = RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous)
    }

    /// Semantic colours. All of them adapt to dark mode and Increase Contrast.
    nonisolated enum Palette {
        /// Screen background behind lists of cards.
        static let screen = Color(.systemGroupedBackground)
        /// Solid card and banner background. Never glass.
        static let card = Color(.secondarySystemGroupedBackground)
        /// A thumbnail whose image has not arrived yet.
        static let placeholder = Color(.secondarySystemFill)
        /// The "+N" tile at the end of a card's strip.
        static let overflow = Color(.tertiarySystemFill)
        /// Keeping: kept borders and badges, Keep actions. The adaptive system-blue accent.
        static let keep = Color.accentColor
        /// Deleting: trash badges and Delete actions.
        static let delete = Color.red
        /// Glyphs drawn on top of photos.
        static let onPhoto = Color.white
        /// The soft shadow that keeps glyphs legible on bright photos.
        static let onPhotoShadow = Color.black.opacity(0.35)
    }
}

// MARK: - Surfaces

extension View {
    /// The solid card surface: 14 pt padding on `secondarySystemGroupedBackground`,
    /// radius 16 with continuous corners, and a hairline edge so a card still reads on a
    /// background of the same colour (the split's sidebar on the iPhone Duo is white too).
    /// Used by moment cards and inline banners.
    func cardSurface() -> some View {
        padding(Theme.Spacing.cardPadding)
            .background(Theme.Palette.card, in: Theme.Shapes.card)
            .overlay {
                Theme.Shapes.card.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
    }

    /// Row chrome for a card inside a plain `List`: clear row background, no separators
    /// and 6/16 insets (§3.3 S3).
    func cardRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(Theme.Insets.cardRow)
    }
}

// MARK: - Motion

/// The app's motion language (blueprint §3.6): every animation is one of these. Under Reduce
/// Motion anything that moves becomes `reducedFade`; fades stay.
nonisolated enum Motion {
    /// Review moving to another moment: the new one slides in from the edge it comes from.
    static var advance: Animation { .smooth(duration: 0.35) }
    /// Content swapped in place: All ↔ One by One, a split's detail, a screen's states.
    static var crossFade: Animation { .easeInOut(duration: 0.25) }
    /// Bars and floating controls showing or hiding, a toast stepping out of their way.
    static var chrome: Animation { .easeInOut(duration: 0.2) }
    /// A row the person removed leaving its list.
    static var listChange: Animation { .smooth(duration: 0.3) }
    /// What replaces a movement under Reduce Motion.
    static var reducedFade: Animation { .easeInOut(duration: 0.2) }
}

extension View {
    /// The navigation transition for a push or a sheet that grows out of `sourceID`: a zoom,
    /// or a cross-fade when Reduce Motion is on (§3.2 rule 8). With `isEnabled` false, the
    /// system's own transition (a sheet opened from somewhere other than its button).
    ///
    /// Pair it with `matchedTransitionSource(id:in:)` on the source view or toolbar item.
    func zoomTransition(sourceID: some Hashable, in namespace: Namespace.ID, isEnabled: Bool = true) -> some View {
        modifier(ZoomOrCrossFadeTransition(sourceID: sourceID, namespace: namespace, isEnabled: isEnabled))
    }
}

private struct ZoomOrCrossFadeTransition<SourceID: Hashable>: ViewModifier {
    let sourceID: SourceID
    let namespace: Namespace.ID
    let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.navigationTransition(
            !isEnabled
                ? AnyNavigationTransition(.automatic)
                : reduceMotion
                    ? AnyNavigationTransition(.crossFade)
                    : AnyNavigationTransition(.zoom(sourceID: sourceID, in: namespace))
        )
    }
}
