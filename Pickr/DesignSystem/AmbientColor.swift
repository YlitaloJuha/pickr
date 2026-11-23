import CoreImage
import CoreImage.CIFilterBuiltins
import PickrCore
import SwiftUI
import UIKit

// Content-adaptive backgrounds (blueprint §3.5, owner decision 2026-11-22, revised: a
// continuous blurred-photo strip behind lists; single photos cross-fade over each other).
//
// For screen agents:
//
//   someScreen.ambientBackground(source)                  one photo (or plain)
//   listScreen.ambientBackground(source, strip: focus)    the photo strip behind a list
//
//   AmbientSource.photo(photoID)   That photo, blurred, tinted and dimmed:
//                                  - Review and Kept moment in All: the focused tile's photo
//                                    (the tile under the focus line, 40 % down the grid, see
//                                    `ScrollFocus`; the first photo until the grid reports);
//                                  - One by One and the Kept photo: the photo shown;
//                                  - the split's detail start views: the first photo of the
//                                    sidebar list's focused moment.
//   AmbientSource.plain            Plain systemGroupedBackground.
//   strip: ScrollFocus<MomentID>   Moments and Kept lists in the stack: every moment row's first
//                                  photo (the one its card's strip leads with) sits behind its
//                                  row and scrolls with it, neighbours blending continuously
//                                  (`AmbientStripLayout`); `source` stands in until rows report.
//
// - One source per tab container, derived from model state and the list or grid, never from
//   the layout itself. In a split the detail column applies it; the sidebar paints nothing
//   (`scrollContentBackground(.hidden)` and no modifier) and shows its own system glass; the
//   sidebar's list still tracks its focus for the detail's start view. In the stack the screen
//   on top applies it.
// - Apply it outside the content that should sit on it: a `List` needs
//   `.scrollContentBackground(.hidden)`; the pager stays clear. It draws behind the content,
//   fills the vertical safe areas and is decorative (hidden from VoiceOver, no hit testing).
// - Cards, tiles, sheets, popovers, Settings and onboarding never get one.
// - A new look fades in over the old one in 0.6 s; the old one stays fully opaque until then
//   and is removed after, so nothing ever passes through the plain background. Looks that
//   arrive during a fade wait for it and only the latest is shown (two layers at most). The
//   strip has no time-based fades: a row whose photo arrives late shows its neighbour's
//   photo until then. Reduce Motion: every change is instant.
// - A container swap (stack ↔ split, rotation, a Duo fold) re-creates the modifier: it shows
//   the current look at once and the strip re-lays out with the rows, with no fetch and no fade
//   (a grid that puts another tile under the focus line fades that photo in as after a scroll).
// - Reduce Transparency or Increase Contrast: the plain background, and nothing is loaded.
//
// Images come from thumbnails the app already shows: `ThumbnailView` reports every final
// image it loads (card strips, filmstrip, grid tiles), and a backdrop at most 64 px on its
// longer side plus the photo's 8×8 average colour (the tint) are drawn from it off the main
// actor: arithmetic, not ML. The 300 newest backdrops stay in memory (about 12 KB each, under
// 4 MB); nothing is persisted. So scrolling a list or a grid normally makes no image request:
// only when a single photo hasn't been shown within 200 ms does the modifier ask `ImageLoading`
// for its small `card` image. Each backdrop is blurred once when it is drawn (Core Image, about a
// 60 pt blur at screen size) and then only scaled to fill: there is no live blur, which rendered
// black on device and cost a full-screen blur per scroll frame. The colour math and the legibility numbers are in
// `AmbientPalette.swift`.

// MARK: - Source

/// What an ambient background is drawn from. Build it from model state only.
nonisolated enum AmbientSource: Hashable, Sendable {
    /// The plain system background.
    case plain
    /// One photo, blurred, tinted and dimmed.
    case photo(PhotoID)
}

// MARK: - Modifier

extension View {
    /// Paints the ambient background for `source` behind this view (blueprint §3.5), or, with a
    /// `strip`, the photo strip behind that list's moment rows (`source` stands in until they
    /// report). See the top of `AmbientColor.swift` for where each screen applies which.
    func ambientBackground(_ source: AmbientSource, strip: ScrollFocus<MomentID>? = nil) -> some View {
        modifier(AmbientBackground(source: source, strip: strip))
    }
}

private struct AmbientBackground: ViewModifier {
    let source: AmbientSource
    let strip: ScrollFocus<MomentID>?

    @Environment(\.imageLoader) private var loader
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The newest source whose backdrop is in the cache. Shown while the current one loads,
    /// so a page turn never flashes the plain background.
    @State private var lastResolved: AmbientSource = .plain
    /// The backdrop of `lastResolved`, held here so the cache can evict it safely.
    @State private var pinned: AmbientBackdrop?
    /// The look fully on screen. `nil` until the modifier appears, so a re-created modifier
    /// shows the current look at once instead of fading in.
    @State private var base: AmbientLook?
    /// The look fading in over `base`; it becomes `base` once fully in.
    @State private var incoming: AmbientLook?

    /// The cross-fade, in seconds.
    private static let fade = 0.6

    func body(content: Content) -> some View {
        let isEnabled = !reduceTransparency && contrast != .increased
        let appearance: AmbientPalette.Appearance = colorScheme == .dark ? .dark : .light
        let cache = AmbientCache.shared
        let target: AmbientLook = if !isEnabled {
            .plain
        } else if strip != nil {
            .strip(appearance)
        } else {
            cache.look(for: source, appearance: appearance, pinned: pinned)
                ?? cache.look(for: lastResolved, appearance: appearance, pinned: pinned)
                ?? .plain
        }

        content
            .background {
                AmbientLayer(
                    looks: [base ?? target] + (incoming.map { [$0] } ?? []),
                    strip: strip,
                    stand: source
                )
            }
            .task(id: TaskKey(source: source, isEnabled: isEnabled)) {
                guard isEnabled else { return }
                await AmbientResolver.resolve(source, loader: loader)
                guard !Task.isCancelled else { return }
                lastResolved = source
                if let backdrop = cache.backdrop(for: source) {
                    pinned = backdrop
                }
            }
            .onChange(of: Step(target: target.key, isFading: incoming != nil), initial: true) { _, _ in
                advance(to: target)
            }
            .task(id: incoming?.key) {
                guard let incoming else { return }
                try? await Task.sleep(for: .seconds(Self.fade))
                guard !Task.isCancelled else { return }
                // The new look is fully in: it becomes the base and the old one goes, unanimated.
                base = incoming
                self.incoming = nil
            }
    }

    /// Fades `target` in over the base, unless a fade is still running: then the latest target
    /// follows when it ends, so there are never more than two layers.
    private func advance(to target: AmbientLook) {
        guard let current = base else {
            base = target
            return
        }
        guard incoming == nil, target.key != current.key else { return }
        if reduceMotion {
            base = target
        } else {
            withAnimation(.easeInOut(duration: Self.fade)) { incoming = target }
        }
    }

    private struct TaskKey: Hashable {
        let source: AmbientSource
        let isEnabled: Bool
    }

    private struct Step: Equatable {
        let target: AmbientLook.Key
        let isFading: Bool
    }
}

// MARK: - Look

/// What the background shows, already tamed for one appearance.
enum AmbientLook: Equatable {
    case plain
    case photo(AmbientPhoto)
    /// The photo strip of the modifier's list.
    case strip(AmbientPalette.Appearance)

    /// Tells looks apart; a layer keeps its identity (and state) while its key stays.
    enum Key: Hashable {
        case plain
        case photo(PhotoID, AmbientPalette.Appearance)
        case strip(AmbientPalette.Appearance)
    }

    var key: Key {
        switch self {
        case .plain: .plain
        case .photo(let photo): .photo(photo.backdrop.id, photo.appearance)
        case .strip(let appearance): .strip(appearance)
        }
    }
}

/// A photo for the blurred background. Equal when it shows the same photo the same way.
struct AmbientPhoto: Equatable {
    let backdrop: AmbientBackdrop
    let appearance: AmbientPalette.Appearance

    static func == (lhs: AmbientPhoto, rhs: AmbientPhoto) -> Bool {
        lhs.backdrop.id == rhs.backdrop.id && lhs.backdrop.color == rhs.backdrop.color
            && lhs.appearance == rhs.appearance
    }
}

/// The base look and, while a fade runs, the incoming one on top. Each look is opaque and keeps
/// its identity when it moves from incoming to base, so the swap at the end of a fade shows the
/// same pixels and removes the old look without a transition.
private struct AmbientLayer: View {
    let looks: [AmbientLook]
    let strip: ScrollFocus<MomentID>?
    /// The list's single photo, drawn by the strip until rows report.
    let stand: AmbientSource

    var body: some View {
        ZStack {
            ForEach(looks, id: \.key) { look in
                AmbientLookView(look: look, strip: strip, stand: stand)
                    .transition(.opacity)
            }
        }
        // Vertical edges are covered directly, never the horizontal ones. No
        // `backgroundExtensionEffect()`: on iOS 27 it rendered a blurred layer (opaque blur)
        // completely black on device.
        .ignoresSafeArea(.all, edges: .vertical)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct AmbientLookView: View {
    let look: AmbientLook
    let strip: ScrollFocus<MomentID>?
    let stand: AmbientSource

    var body: some View {
        switch look {
        case .plain:
            Theme.Palette.screen
        case .photo(let photo):
            AmbientBlurredPhoto(photo: photo)
        case .strip(let appearance):
            if let strip {
                AmbientStripLayer(focus: strip, stand: stand, appearance: appearance)
            } else {
                Theme.Palette.screen
            }
        }
    }
}

/// The (already blurred) backdrop scaled to fill, then the tint and the dim that keep text legible
/// (`AmbientPalette.photoComposite` mirrors these layers).
private struct AmbientBlurredPhoto: View {
    let photo: AmbientPhoto

    var body: some View {
        let dim = AmbientPalette.photoDim(for: photo.appearance)
        Color.clear
            .overlay {
                Image(uiImage: photo.backdrop.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .saturation(AmbientPalette.photoSaturation)
            }
            .overlay {
                Color(ambient: AmbientPalette.photoTint(photo.backdrop.color, for: photo.appearance))
                    .opacity(AmbientPalette.photoTintOpacity)
            }
            .overlay {
                Color(ambient: dim.color).opacity(dim.opacity)
            }
            .clipped()
    }
}

extension Color {
    /// An sRGB colour from the ambient palette.
    init(ambient rgb: AmbientPalette.RGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

// MARK: - Strip

/// The photo strip behind a list (`AmbientStripLayout`): each reported moment row's photo sits
/// behind its row and moves with it, neighbours blend continuously, each segment carries its own
/// tint (backdrops come blurred), and the dim is drawn once (`AmbientPalette.composite`).
/// It reads `focus.frames`, so it re-renders on every scroll frame; nothing else does, and the
/// work is a handful of 64 px images.
private struct AmbientStripLayer: View {
    let focus: ScrollFocus<MomentID>
    let stand: AmbientSource
    let appearance: AmbientPalette.Appearance

    @State private var memo = StripMemo()

    var body: some View {
        let cache = AmbientCache.shared
        // Read so the strip refreshes when a backdrop arrives, even if nothing scrolls.
        let _ = cache.revision
        let frames = focus.frames
        let dim = AmbientPalette.photoDim(for: appearance)
        GeometryReader { proxy in
            let canvas = proxy.frame(in: .global)
            let rows = memo.rows(for: frames, stand: stand, canvas: canvas, cache: cache)
            let pieces = AmbientStripLayout.segments(rows: rows, canvas: canvas).map { segment in
                StripPiece(
                    segment: segment,
                    own: memo.backdrop(at: segment.index),
                    substitute: AmbientStripLayout
                        .substitute(for: segment.index, count: rows.count) { memo.backdrop(at: $0) != nil }
                        .flatMap { memo.backdrop(at: $0) }
                )
            }
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Theme.Palette.screen
                    ForEach(pieces, id: \.segment.id) { piece in
                        StripSegment(
                            segment: piece.segment,
                            own: piece.own,
                            substitute: piece.substitute,
                            appearance: appearance
                        )
                    }
                }
                .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
                Color(ambient: dim.color).opacity(dim.opacity)
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .clipped()
        }
    }
}

/// A segment with the photos it draws: its own, and the neighbour's that stands in for it.
private struct StripPiece {
    let segment: AmbientStripLayout.Segment<MomentID>
    let own: AmbientBackdrop?
    let substitute: AmbientBackdrop?
}

/// What the strip drew last, outside SwiftUI state (it changes every frame): the rows, drawn
/// again while none are reported (the list is covered or being rebuilt), and their backdrops,
/// kept if the cache evicts them while the list is covered.
private final class StripMemo {
    private var rows: [AmbientStripLayout.Row<MomentID>] = []
    private var backdrops: [PhotoID: AmbientBackdrop] = [:]

    /// The rows to draw: the reported ones, else the last reported, else `stand` filling the
    /// canvas. Refreshes their backdrops from the cache.
    func rows(
        for frames: [MomentID: CGRect],
        stand: AmbientSource,
        canvas: CGRect,
        cache: AmbientCache
    ) -> [AmbientStripLayout.Row<MomentID>] {
        if !frames.isEmpty {
            rows = AmbientStripLayout.rows(frames)
        }
        var drawn = rows
        if drawn.isEmpty, case .photo(let photo) = stand {
            drawn = [AmbientStripLayout.Row(id: MomentID(anchor: photo), frame: canvas)]
        }
        var kept: [PhotoID: AmbientBackdrop] = [:]
        for row in drawn {
            let photo = row.id.anchor
            if let backdrop = cache.backdrop(for: .photo(photo)) ?? backdrops[photo] {
                kept[photo] = backdrop
            }
        }
        backdrops = kept
        shown = drawn
        return drawn
    }

    /// The backdrop of row `index` of the rows last returned.
    func backdrop(at index: Int) -> AmbientBackdrop? {
        shown.indices.contains(index) ? backdrops[shown[index].id.anchor] : nil
    }

    private var shown: [AmbientStripLayout.Row<MomentID>] = []
}

/// One photo of the strip, placed and masked by the layout: its own backdrop, or the nearest
/// neighbour's until its own arrives. Stateless, so a segment can never be left transparent.
private struct StripSegment: View {
    let segment: AmbientStripLayout.Segment<MomentID>
    let own: AmbientBackdrop?
    let substitute: AmbientBackdrop?
    let appearance: AmbientPalette.Appearance

    var body: some View {
        let rect = segment.rect
        ZStack {
            if let backdrop = own ?? substitute {
                StripPhoto(backdrop: backdrop, appearance: appearance)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .clipped()
        .mask {
            LinearGradient(stops: maskStops, startPoint: .top, endPoint: .bottom)
        }
        .offset(x: rect.minX, y: rect.minY)
    }

    private var maskStops: [Gradient.Stop] {
        let stops = segment.mask.isEmpty
            ? [AmbientStripLayout.MaskStop(location: 0, opacity: 1), AmbientStripLayout.MaskStop(location: 1, opacity: 1)]
            : segment.mask
        return stops.map { Gradient.Stop(color: .black.opacity($0.opacity), location: $0.location) }
    }
}

/// A strip photo (already blurred) scaled to fill its segment, with its own tint; the strip dims them all
/// at once.
private struct StripPhoto: View {
    let backdrop: AmbientBackdrop
    let appearance: AmbientPalette.Appearance

    var body: some View {
        Image(uiImage: backdrop.image)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .saturation(AmbientPalette.photoSaturation)
            .overlay {
                Color(ambient: AmbientPalette.photoTint(backdrop.color, for: appearance))
                    .opacity(AmbientPalette.photoTintOpacity)
            }
    }
}

// MARK: - Cache

/// A photo's backdrop: a tiny, already blurred image and its average colour, the tint.
nonisolated struct AmbientBackdrop: Sendable {
    let id: PhotoID
    let image: UIImage
    let color: AmbientPalette.RGB
}

/// Backdrops per photo ID, in memory only. `revision` changes whenever one is stored, so the
/// strip can show a photo that arrives while nothing scrolls.
@MainActor
@Observable
final class AmbientCache {
    static let shared = AmbientCache()

    private enum Entry {
        case backdrop(AmbientBackdrop)
        /// The photo has no image (deleted, hidden or failed); it isn't requested again.
        case unavailable
    }

    /// About 12 KB per backdrop (64 × 48 px): under 4 MB in all.
    private static let capacity = 300

    /// Bumped on every store.
    private(set) var revision = 0

    @ObservationIgnored private var entries: [PhotoID: Entry] = [:]
    /// Oldest first; the first is evicted when `entries` is full.
    @ObservationIgnored private var order: [PhotoID] = []

    private init() {}

    /// Records an image `ThumbnailView` loaded: unless the photo has a backdrop already, one is
    /// drawn from it, with its average colour, off the main actor.
    func record(_ image: UIImage, for id: PhotoID) async {
        guard !hasBackdrop(id) else { return }
        guard let backdrop = await AmbientSampler.backdrop(of: image, id: id) else { return }
        store(backdrop, for: id)
    }

    /// Whether the photo needs no request: it has a backdrop or is known to have no image.
    fileprivate func has(_ id: PhotoID) -> Bool {
        entries[id] != nil
    }

    /// Stores a backdrop, or `nil` for a photo that has no image. The first backdrop stays, so
    /// a look never changes under a modifier that shows it.
    fileprivate func store(_ backdrop: AmbientBackdrop?, for id: PhotoID) {
        let entry: Entry
        switch (backdrop, entries[id]) {
        case (_, .backdrop?), (nil, .unavailable?):
            return
        case (let backdrop?, _):
            entry = .backdrop(backdrop)
        case (nil, nil):
            entry = .unavailable
        }
        if entries.updateValue(entry, forKey: id) == nil {
            order.append(id)
        }
        while order.count > Self.capacity {
            entries[order.removeFirst()] = nil
        }
        revision &+= 1
    }

    /// The backdrop a modifier should hold while it shows `source`.
    func backdrop(for source: AmbientSource) -> AmbientBackdrop? {
        guard case .photo(let id) = source, case .backdrop(let backdrop) = entries[id] else { return nil }
        return backdrop
    }

    /// The look for `source`, or `nil` while its backdrop hasn't been drawn yet. `pinned`
    /// stands in for a backdrop the cache has evicted.
    func look(
        for source: AmbientSource,
        appearance: AmbientPalette.Appearance,
        pinned: AmbientBackdrop? = nil
    ) -> AmbientLook? {
        guard case .photo(let id) = source else { return .plain }
        switch entries[id] {
        case .backdrop(let backdrop):
            return .photo(AmbientPhoto(backdrop: backdrop, appearance: appearance))
        case .unavailable:
            return .plain
        case nil:
            guard let pinned, pinned.id == id else { return nil }
            return .photo(AmbientPhoto(backdrop: pinned, appearance: appearance))
        }
    }

    private func hasBackdrop(_ id: PhotoID) -> Bool {
        if case .backdrop = entries[id] { true } else { false }
    }
}

// MARK: - Loading

private enum AmbientResolver {
    /// How long to wait for on-screen thumbnails to report their images before asking the
    /// loader, so the common case makes no request of its own.
    static let thumbnailGrace: Duration = .milliseconds(200)

    /// Draws the backdrop `source` needs if the cache doesn't have it yet: after the grace
    /// period, from the first (fast, degraded) `card` image, ending the request at once.
    static func resolve(_ source: AmbientSource, loader: any ImageLoading) async {
        guard case .photo(let id) = source else { return }
        let cache = AmbientCache.shared
        guard !cache.has(id) else { return }

        try? await Task.sleep(for: thumbnailGrace)
        guard !Task.isCancelled, !cache.has(id) else { return }

        var first: UIImage?
        for await image in loader.images(for: id, size: .card) {
            first = image
            break
        }
        // A cancelled request yields nothing; that says nothing about the photo.
        guard !Task.isCancelled || first != nil else { return }
        let backdrop: AmbientBackdrop? = if let first {
            await AmbientSampler.backdrop(of: first, id: id)
        } else {
            nil
        }
        cache.store(backdrop, for: id)
    }
}

private nonisolated enum AmbientSampler {
    /// The longer side of a backdrop, in pixels.
    static let backdropSide: CGFloat = 64
    /// The side of the downsample the average colour is taken from.
    static let averageSide = 8

    /// Draws the backdrop (at most 64 px on its longer side, in the image's orientation) and
    /// averages an 8×8 downsample of it. Runs off the main actor; `nil` for an unreadable image.
    @concurrent
    static func backdrop(of image: UIImage, id: PhotoID) async -> AmbientBackdrop? {
        guard let cgImage = image.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              cgImage.width > 0, cgImage.height > 0
        else { return nil }
        let scale = min(1, backdropSide / CGFloat(max(cgImage.width, cgImage.height)))
        let width = max(1, Int((CGFloat(cgImage.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(cgImage.height) * scale).rounded()))
        guard let context = bitmap(width: width, height: height, space: space, data: nil) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage(),
              let color = averageColor(of: small, space: space)
        else { return nil }
        return AmbientBackdrop(
            id: id,
            image: UIImage(cgImage: blurred(small) ?? small, scale: 1, orientation: image.imageOrientation),
            color: color
        )
    }

    /// Core Image context for the one-off backdrop blur. Thread-safe; shared to avoid creating one
    /// per photo.
    private static let blurContext = CIContext(options: [.cacheIntermediates: false])

    /// The backdrop with its blur baked in. Edges are clamped first, so they don't darken.
    private static func blurred(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(AmbientPalette.backdropBlurRadius)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return blurContext.createCGImage(output, from: input.extent)
    }

    private static func averageColor(of image: CGImage, space: CGColorSpace) -> AmbientPalette.RGB? {
        let side = averageSide
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = bitmap(width: side, height: side, space: space, data: buffer.baseAddress) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? AmbientPalette.averageColor(rgba: bytes) : nil
    }

    /// An 8-bit premultiplied RGBA sRGB bitmap context.
    private static func bitmap(
        width: Int,
        height: Int,
        space: CGColorSpace,
        data: UnsafeMutableRawPointer?
    ) -> CGContext? {
        let context = CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.interpolationQuality = .medium
        return context
    }
}

#if DEBUG
#Preview("Ambient backgrounds") {
    @Previewable @State var listFocus = ScrollFocus<MomentID>()
    @Previewable @State var gridFocus = ScrollFocus<PhotoID>()
    let records = PreviewPhotos.records(count: 30)
    let moments = stride(from: 0, to: 30, by: 3).map { Moment(photos: Array(records[$0..<($0 + 3)])) }
    TabView {
        Tab(String("List"), systemImage: "rectangle.stack") {
            NavigationStack {
                List {
                    ForEach(moments) { moment in
                        MomentCard(moment: moment)
                            .scrollFocusItem(moment.id, in: listFocus)
                            .cardRow()
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollFocusContainer(listFocus)
                .ambientBackground(.photo(records[0].id), strip: listFocus)
                .navigationTitle("Moments")
            }
        }
        Tab(String("Grid"), systemImage: "square.grid.2x2") {
            NavigationStack {
                PhotoGrid(photos: records.map(\.id), focus: gridFocus) { _, id in PhotoTile(id: id) }
                    .ambientBackground(.photo(gridFocus.focused ?? records[0].id))
                    .navigationTitle("All")
            }
        }
        Tab("Photo", systemImage: "photo") {
            NavigationStack {
                Color.clear
                    .ambientBackground(.photo(records[4].id))
                    .navigationTitle("One by One")
            }
        }
    }
    .environment(\.imageLoader, SwatchImageLoader())
}
#endif
