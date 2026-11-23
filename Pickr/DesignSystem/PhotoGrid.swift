import PickrCore
import SwiftUI

// The photo grid (§3.3 S4 All, S8b; ADAPTIVE.md §6.1, §9).
//
// For screen agents:
//
//   PhotoGrid(photos:, position:, dragSelection:, focus:, onLayoutChange:) { index, id in PhotoTile(…) }
//
//   - Columns come from the grid's own width: 3–6, `Int(width / 180)`, so tiles grow on wide
//     windows instead of multiplying (iPhone 3, Duo open 3, iPad 13" landscape detail 5).
//   - `dragSelection` (Review only) turns on range-painting (`DragSelect.swift`) and tells the
//     tiles they can be kept, so a pointer hovering an unkept tile shows the hollow keep circle.
//     Kept (read-only) passes nil.
//   - `focus` tracks the tile under the focus line (`ScrollFocus`), for the screen's ambient
//     background.
//   - `onLayoutChange` reports `PhotoGridLayout` (columns, tile side) to an ancestor, for the
//     keyboard focus ring's ↑/↓ rows. Tiles read the same value as `\.photoGridLayout`.
//   - Tiles choose their image size from the grid (`\.photoTileContext`): `tile` (360 px)
//     while that is sharp enough, otherwise a `viewer` request of the tile's size, decided
//     once a resize settles. Preheating uses the same size.
//   - Callers still add each tile's tap, context menu and accessibility actions.

/// A scrolling grid of square photos. It preheats images ±12 photos around the visible
/// range at the tiles' size, stops preheating photos that leave that window, and stops
/// everything when it disappears. It does not preheat while the system prefers reduced
/// resource usage.
struct PhotoGrid<Tile: View>: View {
    let photos: [PhotoID]
    /// The size class tiles start from (`PhotoTile` uses `.tile`).
    let size: ImageSizeClass
    private let position: Binding<PhotoID?>?
    private let dragSelection: DragSelection?
    private let focus: ScrollFocus<PhotoID>?
    private let onLayoutChange: ((PhotoGridLayout) -> Void)?
    let tile: (_ index: Int, _ id: PhotoID) -> Tile

    @Environment(\.imageLoader) private var loader
    @Environment(\.systemPrefersReducedResourceUsage) private var prefersReducedResourceUsage
    @Environment(\.displayScale) private var displayScale

    /// The photos currently being preheated, at `preheatedSize`.
    @State private var preheated: Set<PhotoID> = []
    @State private var preheatedSize: ImageSizeClass?
    /// The grid's own width, measured.
    @State private var width: CGFloat = 0
    /// The tile side images are requested for. Follows `layout.side` once a resize settles.
    @State private var imageSide: CGFloat = 0
    /// The scroll position when the caller doesn't bind one.
    @State private var ownPosition: PhotoID?
    @State private var scrollMetrics = ScrollMetrics()

    /// - Parameters:
    ///   - size: the class tiles start from. `.tile` upgrades to `.viewer` for large tiles.
    ///   - position: the photo scrolled to the top, read and written as the grid scrolls,
    ///     for example to return to the photo last shown in One by One.
    ///   - dragSelection: turns on drag-select (Review). `nil` for read-only grids.
    ///   - focus: receives the tiles' frames, for the ambient background. `nil` tracks nothing.
    ///   - onLayoutChange: called with the grid's layout at first layout and whenever it
    ///     changes (a resize, a rotation).
    init(
        photos: [PhotoID],
        size: ImageSizeClass = .tile,
        position: Binding<PhotoID?>? = nil,
        dragSelection: DragSelection? = nil,
        focus: ScrollFocus<PhotoID>? = nil,
        onLayoutChange: ((PhotoGridLayout) -> Void)? = nil,
        @ViewBuilder tile: @escaping (_ index: Int, _ id: PhotoID) -> Tile
    ) {
        self.photos = photos
        self.size = size
        self.position = position
        self.dragSelection = dragSelection
        self.focus = focus
        self.onLayoutChange = onLayoutChange
        self.tile = tile
    }

    var body: some View {
        let layout = PhotoGridLayout(width: width)
        let tileContext = PhotoTileContext(
            imageSize: PhotoGridLayout.tileImageSize(side: imageSide, displayScale: displayScale, base: size),
            allowsKeeping: dragSelection != nil
        )

        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: layout.gridItems, spacing: layout.spacing) {
                    ForEach(photos.enumerated(), id: \.element) { index, id in
                        tile(index, id)
                            .scrollFocusItem(id, in: focus)
                    }
                }
                .scrollTargetLayout()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
                    width = newWidth
                }
                .dragSelect(
                    photos: photos,
                    layout: layout,
                    selection: dragSelection,
                    viewport: PhotoGridMetrics.viewportSpace,
                    scrollMetrics: scrollMetrics,
                    scrollTo: { id, anchor in proxy.scrollTo(id, anchor: anchor) }
                )
                .environment(\.photoGridLayout, layout)
                .environment(\.photoTileContext, tileContext)
            }
            .coordinateSpace(.named(PhotoGridMetrics.viewportSpace))
            .contentMargins(.horizontal, Theme.Spacing.large, for: .scrollContent)
            .contentMargins(.vertical, Theme.Spacing.small, for: .scrollContent)
            .scrollPosition(id: position ?? $ownPosition)
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
                scrollMetrics.geometry = geometry
            }
            .onScrollTargetVisibilityChange(idType: PhotoID.self, threshold: 0.01) { visible in
                updatePreheating(visible: visible, size: tileContext.imageSize)
            }
            .scrollFocusContainer(focus)
        }
        .onChange(of: layout, initial: true) { _, newLayout in
            onLayoutChange?(newLayout)
        }
        .task(id: layout.side) {
            // The first measurement applies at once; later ones wait for a resize to settle,
            // so a live resize never re-requests every visible image on each frame.
            if imageSide > 0 {
                try? await Task.sleep(for: PhotoGridMetrics.resizeSettleDelay)
                guard !Task.isCancelled else { return }
            }
            imageSide = layout.side
        }
        .onChange(of: tileContext.imageSize) { _, _ in
            stopPreheating(preheated)
        }
        .onChange(of: photos) { _, newPhotos in
            stopPreheating(preheated.subtracting(newPhotos))
        }
        .onChange(of: prefersReducedResourceUsage) { _, prefersReduced in
            if prefersReduced { stopPreheating(preheated) }
        }
        .onDisappear {
            stopPreheating(preheated)
        }
    }

    /// Moves the preheat window to ±12 photos around the visible ones.
    private func updatePreheating(visible: [PhotoID], size: ImageSizeClass) {
        guard !prefersReducedResourceUsage, !visible.isEmpty, !photos.isEmpty else { return }
        if preheatedSize != size {
            stopPreheating(preheated)
            preheatedSize = size
        }
        let indexByID = Dictionary(photos.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let visibleIndices = visible.compactMap { indexByID[$0] }
        guard let first = visibleIndices.min(), let last = visibleIndices.max() else { return }

        let window = photos[max(0, first - PhotoGridMetrics.preheatMargin)...min(photos.count - 1, last + PhotoGridMetrics.preheatMargin)]
        let wanted = Set(window)
        stopPreheating(preheated.subtracting(wanted))
        let starting = window.filter { !preheated.contains($0) }
        if !starting.isEmpty {
            loader.preheat(starting, size: size)
        }
        preheated = wanted
    }

    private func stopPreheating(_ ids: Set<PhotoID>) {
        guard !ids.isEmpty, let preheatedSize else { return }
        loader.stopPreheating(Array(ids), size: preheatedSize)
        preheated.subtract(ids)
    }
}

/// Values shared by every `PhotoGrid` (a generic type cannot hold static stored properties).
private enum PhotoGridMetrics {
    /// Photos preheated on each side of the visible range.
    static let preheatMargin = 12
    /// How long the tile side must hold still before images are re-requested at a new size.
    static let resizeSettleDelay: Duration = .milliseconds(300)
    /// The scroll view's own coordinate space, for drag-select's auto-scroll.
    static let viewportSpace = "PhotoGrid.viewport"
}

/// The latest scroll geometry, kept outside SwiftUI state so scrolling never re-renders the
/// grid. Drag-select reads it while it auto-scrolls.
@MainActor
final class ScrollMetrics {
    var geometry: ScrollGeometry?
}

// MARK: - Layout

/// The grid's columns and tile size, derived from its own width (ADAPTIVE.md §6.1).
nonisolated struct PhotoGridLayout: Equatable, Sendable {
    static let minimumColumns = 3
    static let maximumColumns = 6
    /// One column per 180 pt of grid width.
    static let widthPerColumn: CGFloat = 180
    /// The largest tile, in pixels, the `tile` size class (360 px) serves sharply.
    static let tilePixels: CGFloat = 360
    /// Viewer requests for large tiles round the side up to this step, so small width
    /// changes reuse the same request.
    static let viewerSideStep: CGFloat = 50

    let columns: Int
    /// The side of one square tile, in points.
    let side: CGFloat
    /// The gap between tiles, both ways.
    let spacing: CGFloat

    init(width: CGFloat, spacing: CGFloat = Theme.Size.gridSpacing) {
        let columns = Self.columnCount(forWidth: width)
        self.columns = columns
        self.spacing = spacing
        self.side = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    /// `min(6, max(3, Int(width / 180)))`.
    static func columnCount(forWidth width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return minimumColumns }
        return min(maximumColumns, max(minimumColumns, Int(width / widthPerColumn)))
    }

    var gridItems: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns)
    }

    /// The distance from one row's top to the next.
    var rowStep: CGFloat { side + spacing }

    /// Rows needed for `count` photos.
    func rows(for count: Int) -> Int {
        count <= 0 ? 0 : (count + columns - 1) / columns
    }

    /// The photo at `point` in the grid's own coordinates, clamped to the nearest tile: a
    /// point in a gap, left of the first column or right of the last picks the closest
    /// tile, above the grid the first row, below the last tile the last photo. `nil` for no
    /// photos or before the grid has a size.
    func index(at point: CGPoint, count: Int) -> Int? {
        guard count > 0, side > 0, point.x.isFinite, point.y.isFinite else { return nil }
        let column = min(max(Int((point.x / rowStep).rounded(.down)), 0), columns - 1)
        let row = min(max(Int((point.y / rowStep).rounded(.down)), 0), rows(for: count) - 1)
        return min(row * columns + column, count - 1)
    }

    /// The size class for a tile of `side` points: `base` while `base` is `.tile` and
    /// 360 px covers the tile, otherwise a `viewer` request of the tile's size (rounded up
    /// to 50 pt). Other bases are returned unchanged.
    static func tileImageSize(side: CGFloat, displayScale: CGFloat, base: ImageSizeClass = .tile) -> ImageSizeClass {
        guard base == .tile, side.isFinite, side > 0, side * max(displayScale, 1) > tilePixels else { return base }
        let requested = (side / viewerSideStep).rounded(.up) * viewerSideStep
        return .viewer(CGSize(width: requested, height: requested))
    }
}

/// What a tile needs from its grid; changes far less often than `PhotoGridLayout`.
nonisolated struct PhotoTileContext: Equatable, Sendable {
    /// The size class tiles load at, the same one the grid preheats.
    var imageSize: ImageSizeClass = .tile
    /// The grid toggles keep (Review): pointer hover shows the keep affordance.
    var allowsKeeping = false
}

extension EnvironmentValues {
    /// The enclosing grid's layout; `nil` outside a `PhotoGrid`.
    @Entry var photoGridLayout: PhotoGridLayout? = nil
    /// The enclosing grid's image size and keep behaviour, for `PhotoTile`.
    @Entry var photoTileContext = PhotoTileContext()
}
