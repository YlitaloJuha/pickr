import PickrCore
import SwiftUI

/// A square grid tile with solid (non-glass) badges (§3.3 S4 Grid mode, §2.5 rail 4):
///
/// - kept: a 3 pt accent border and a top-trailing `checkmark.circle.fill`;
/// - protected: a bottom-leading `heart.fill`;
/// - will be deleted: a bottom-trailing `trash.circle.fill`.
///
/// The tile is one accessibility element with the `.isSelected` trait while kept. The
/// caller adds the tap (Review toggles keep) and any context menu or accessibility actions.
///
/// Inside a `PhotoGrid` it loads at the grid's image size (`\.photoTileContext`), so large
/// tiles on wide windows stay sharp. Pointer hover (ADAPTIVE.md §8) highlights the tile's
/// rounded shape; in a grid that toggles keep (Review), hovering an unkept tile also shows a
/// hollow circle where the kept checkmark appears. Hover never shows for touch.
struct PhotoTile: View {
    let id: PhotoID
    let isKept: Bool
    let isProtected: Bool
    let willDelete: Bool
    private let label: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.photoTileContext) private var context

    /// A pointer is over the tile (never set by touch).
    @State private var isHovering = false

    /// - Parameter accessibilityLabel: what VoiceOver says, usually from
    ///   `PhotoAccessibility.label(index:total:captured:isProtected:)`. `nil` says "Photo".
    init(
        id: PhotoID,
        isKept: Bool = false,
        isProtected: Bool = false,
        willDelete: Bool = false,
        accessibilityLabel: String? = nil
    ) {
        self.id = id
        self.isKept = isKept
        self.isProtected = isProtected
        self.willDelete = willDelete
        self.label = accessibilityLabel
    }

    /// A tile for photo `index` of a moment of `total`, labelled "Photo 2 of 5, 13:25:08,
    /// favorite". `showsProtection: false` hides the heart (and its spoken "favorite").
    init(
        record: AssetRecord,
        index: Int,
        total: Int,
        isKept: Bool = false,
        willDelete: Bool = false,
        showsProtection: Bool = true
    ) {
        let isProtected = showsProtection && record.isProtected
        self.init(
            id: record.id,
            isKept: isKept,
            isProtected: isProtected,
            willDelete: willDelete,
            accessibilityLabel: PhotoAccessibility.label(
                index: index, total: total, captured: record.created, isProtected: isProtected
            )
        )
    }

    var body: some View {
        ThumbnailView(id: id, size: context.imageSize)
            .overlay {
                if isKept {
                    Theme.Shapes.tile
                        .strokeBorder(Theme.Palette.keep, lineWidth: Theme.Size.keptBorder)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isKept {
                    TileBadge(systemImage: "checkmark.circle.fill", tint: Theme.Palette.keep)
                        .transition(badgeTransition)
                } else if isHovering && context.allowsKeeping {
                    // "Click to keep": solid content, never glass.
                    TileBadge(systemImage: "circle", tint: nil)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isProtected {
                    TileBadge(systemImage: "heart.fill", tint: nil)
                        .transition(badgeTransition)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if willDelete {
                    TileBadge(systemImage: "trash.circle.fill", tint: Theme.Palette.delete)
                        .transition(badgeTransition)
                }
            }
            .clipShape(Theme.Shapes.tile)
            .contentShape(Theme.Shapes.tile)
            .contentShape(.contextMenuPreview, Theme.Shapes.tile)
            .contentShape(.hoverEffect, Theme.Shapes.tile)
            .hoverEffect(.highlight)
            .onHover { isHovering = $0 }
            .animation(.snappy(duration: 0.2), value: isKept)
            .animation(.snappy(duration: 0.2), value: willDelete)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label ?? String(localized: "Photo", comment: "VoiceOver label of a photo tile."))
            .accessibilityValue(
                willDelete
                    ? String(localized: "To delete", comment: "VoiceOver value of a photo tile that will be deleted.")
                    : ""
            )
            .accessibilityAddTraits(isKept ? .isSelected : [])
    }

    /// Badges fade in place under Reduce Motion: no pop, no bounce.
    private var badgeTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity)
    }
}

/// A solid glyph on top of a photo: a white symbol, drawn on a tinted circle for the
/// `.circle.fill` symbols (`checkmark.circle.fill`, `trash.circle.fill`).
private struct TileBadge: View {
    let systemImage: String
    let tint: Color?

    var body: some View {
        Image(systemName: systemImage)
            .symbolRenderingMode(.palette)
            .foregroundStyle(Theme.Palette.onPhoto, tint ?? Theme.Palette.onPhoto)
            .font(.title3)
            // Badges scale with text but stay small enough for a 104 pt tile.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .shadow(color: Theme.Palette.onPhotoShadow, radius: 2, y: 1)
            .padding(Theme.Spacing.small)
            .accessibilityHidden(true)
    }
}

/// What VoiceOver says about one photo (§3.3 S4 accessibility).
enum PhotoAccessibility {
    /// "Photo 2 of 5, 13:25:08, favorite", plus ", kept" when `isKept` (the pager).
    ///
    /// - Parameter index: zero-based position in the moment.
    static func label(index: Int, total: Int, captured: Date?, isProtected: Bool, isKept: Bool = false) -> String {
        var parts = [
            String(
                localized: "Photo \(index + 1) of \(total)",
                comment: "VoiceOver: a photo's position in its moment. 1: position, 2: number of photos."
            ),
        ]
        if let captured {
            parts.append(captured.formatted(date: .omitted, time: .standard))
        }
        if isProtected {
            parts.append(String(localized: "favorite", comment: "VoiceOver: the photo is a favorite or rated (protected)."))
        }
        if isKept {
            parts.append(String(localized: "kept", comment: "VoiceOver: the photo is marked to keep."))
        }
        return joined(parts)
    }

    /// Joins the parts of a VoiceOver label with pauses, never with "and": the parts are
    /// separate facts, not a list.
    static func joined(_ parts: [String]) -> String {
        parts.joined(separator: String(localized: ", ", comment: "Separator between the parts of a VoiceOver label."))
    }
}

#if DEBUG
#Preview("Tiles") {
    let records = PreviewPhotos.records(count: 6)
    PhotoGrid(photos: records.map(\.id)) { index, _ in
        PhotoTile(
            record: records[index],
            index: index,
            total: records.count,
            isKept: index.isMultiple(of: 2),
            willDelete: !index.isMultiple(of: 2)
        )
    }
    .environment(\.imageLoader, SwatchImageLoader())
}
#endif
