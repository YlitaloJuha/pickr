import PickrCore
import PickrModels
import SwiftUI
import TipKit
import UIKit

/// Review in All (§3.3 S4 Grid mode, ADAPTIVE S4, §6.1, §7, §8, §9): every photo of the moment
/// in a `PhotoGrid` whose columns follow its own width.
///
/// - A tap keeps or unkeeps a photo. Kept tiles get the accent border and checkmark; once one
///   is kept, the others show the trash badge. Protected favorites show a heart.
/// - Drag sideways (or click-drag with a pointer) to keep or unkeep a run of tiles.
/// - Long press: Keep / Unkeep and View (One by One at that photo), with a large preview.
/// - The keyboard focus ring (a solid 2 pt accent outline, outside the tile) marks the tile
///   the arrow keys reached; it scrolls into view as it moves.
/// - `TapToKeepTip` points at the first tile.
struct ReviewGrid: View {
    /// Passed into context-menu previews, which iOS hosts outside this view's environment.
    @Environment(\.imageLoader) private var previewLoader
    let session: ReviewSession
    let moment: Moment
    /// The photos marked to keep (the session's, or the last ones while Review pops).
    let kept: Set<PhotoID>
    /// The tile under the keyboard focus ring, or `nil` while hidden.
    let ring: Int?
    /// A tile was tapped (or activated with VoiceOver): toggle it, with the keep haptic.
    let onTap: (PhotoID) -> Void
    /// Drag-select changed a tile: toggle it without a haptic (DragSelect plays its own).
    let onDragToggle: (PhotoID) -> Void
    let onLayoutChange: (PhotoGridLayout) -> Void
    /// Tracks the tile under the focus line, for the screen's background.
    let focus: ScrollFocus<PhotoID>

    @Environment(SettingsModel.self) private var settings

    /// The photo at the top of the grid, read and written as it scrolls.
    @State private var position: PhotoID?
    @State private var layout: PhotoGridLayout?
    @State private var height: CGFloat = 0

    private let tapTip = TapToKeepTip()

    var body: some View {
        let photos = moment.photos
        let hasKept = photos.contains { kept.contains($0.id) }
        let showsProtection = settings.protectFavorites

        PhotoGrid(
            photos: moment.photoIDs,
            position: $position,
            dragSelection: DragSelection(
                isKept: { session.selection.kept.contains($0) },
                toggle: onDragToggle
            ),
            focus: focus,
            onLayoutChange: { newLayout in
                layout = newLayout
                onLayoutChange(newLayout)
            }
        ) { index, id in
            let isKept = kept.contains(id)
            PhotoTile(
                record: photos[index],
                index: index,
                total: photos.count,
                isKept: isKept,
                willDelete: hasKept && !isKept,
                showsProtection: showsProtection
            )
            .overlay {
                if index == ring {
                    FocusRing()
                }
            }
            .onTapGesture { onTap(id) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isKept
                ? Text("Unkeeps the photo.", comment: "VoiceOver hint of a kept photo tile in Review.")
                : Text("Keeps the photo.", comment: "VoiceOver hint of a photo tile in Review."))
            .accessibilityAction { onTap(id) }
            .accessibilityAction(named: Text("View", comment: "Shows this photo in One by One.")) {
                session.showSingle(id)
            }
            .contextMenu {
                if isKept {
                    Button { onTap(id) } label: {
                        Label { Text("Unkeep", comment: "Review: unmark a kept photo.") } icon: { Image(systemName: "circle") }
                    }
                } else {
                    Button { onTap(id) } label: {
                        Label { Text("Keep", comment: "Review: mark a photo to keep.") } icon: { Image(systemName: "checkmark.circle") }
                    }
                }
                Button { session.showSingle(id) } label: {
                    Label {
                        Text("View", comment: "Review: show this photo in One by One.")
                    } icon: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                }
            } preview: {
                ReviewPhotoPreview(id: id)
                    .environment(\.imageLoader, previewLoader)
            }
            .popoverTip(index == 0 ? tapTip : nil, arrowEdge: .top)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
            height = newHeight
        }
        .onAppear {
            // Back from One by One: start at the photo shown there (ADAPTIVE §3.4).
            if session.singleIndex > 0, let photo = session.currentPhoto {
                position = photo.id
            }
        }
        .onChange(of: ring) { _, newRing in
            scrollIntoView(newRing)
        }
    }

    /// Scrolls the ring's row into view when it leaves the rows that fit the grid's height.
    private func scrollIntoView(_ ring: Int?) {
        guard let ring, let layout, layout.rowStep > 0, moment.photos.indices.contains(ring) else { return }
        let ids = moment.photoIDs
        let row = ring / layout.columns
        let topIndex = position.flatMap { ids.firstIndex(of: $0) } ?? 0
        let topRow = topIndex / layout.columns
        // The grid runs under the bars, so one row less than fits counts as visible.
        let visibleRows = max(1, Int(height / layout.rowStep) - 1)
        if row < topRow {
            position = ids[row * layout.columns]
        } else if row >= topRow + visibleRows {
            position = ids[min((row - visibleRows + 1) * layout.columns, ids.count - 1)]
        }
    }
}

/// The keyboard focus ring: solid content, never glass, drawn just outside the tile so it
/// stays distinct from a kept tile's border.
private struct FocusRing: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.tile + Self.outset, style: .continuous)
            .strokeBorder(Theme.Palette.keep, lineWidth: 2)
            .padding(-Self.outset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private static let outset: CGFloat = 3
}

/// The large context-menu preview of one photo: the tile image at once, then a sharper one,
/// shown whole (not cropped).
private struct ReviewPhotoPreview: View {
    let id: PhotoID

    @Environment(\.imageLoader) private var loader
    @State private var image: UIImage?

    private static let side: CGFloat = 340

    var body: some View {
        Group {
            if let image, image.size.width > 0, image.size.height > 0 {
                let aspect = image.size.width / image.size.height
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(
                        width: aspect >= 1 ? Self.side : Self.side * aspect,
                        height: aspect >= 1 ? Self.side / aspect : Self.side
                    )
            } else {
                ThumbnailView(id: id, size: .tile)
                    .frame(width: Self.side, height: Self.side)
            }
        }
        .accessibilityHidden(true)
        .task(id: id) {
            for await next in loader.images(for: id, size: .tile) {
                image = next
            }
            for await next in loader.images(for: id, size: .viewer(CGSize(width: Self.side, height: Self.side))) {
                image = next
            }
        }
    }
}
