import PickrCore
import SwiftUI

// One of the three files allowed to use explicit glass (§3.2 rule 2). Call-site contract:
// WP9 reuses this view unchanged in the Kept moment's One by One (without a glass namespace).

/// A horizontal strip of thumbnails in clear glass; a tap jumps to that photo.
///
/// - 40 pt thumbnails, 56 pt for the current one, at the `filmstrip` size class. Those images
///   also feed the ambient background, so the blurred photo needs no request of its own.
/// - Kept photos show a checkmark, photos to delete a trash badge (solid, not glass).
/// - It hugs its thumbnails while they fit, up to 560 pt (ADAPTIVE S4), and scrolls (keeping
///   the current one centred) when they don't. Callers centre it; they add no width frame.
/// - Each thumbnail is a button for VoiceOver ("Photo 2 of 5, kept"), selected when current,
///   with a pointer hover highlight.
struct Filmstrip: View {
    let photos: [PhotoID]
    @Binding var index: Int
    let badge: (PhotoID) -> PagerBadge
    /// The `GlassEffectContainer` namespace for `glassEffectID` morphs, when there is one.
    let glassNamespace: Namespace.ID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        photos: [PhotoID],
        index: Binding<Int>,
        badge: @escaping (PhotoID) -> PagerBadge,
        glassNamespace: Namespace.ID? = nil
    ) {
        self.photos = photos
        _index = index
        self.badge = badge
        self.glassNamespace = glassNamespace
    }

    private static let thumbnailSide: CGFloat = 40
    private static let currentSide: CGFloat = 56
    private static let spacing: CGFloat = 6
    private static let verticalInset: CGFloat = 6
    /// Wider than the vertical inset, so the capsule's round ends clear the end thumbnails.
    private static let horizontalInset: CGFloat = 14

    /// The strip's width with every thumbnail showing (one of them current).
    private var naturalWidth: CGFloat {
        guard !photos.isEmpty else { return 0 }
        let others = CGFloat(photos.count - 1)
        return others * (Self.thumbnailSide + Self.spacing) + Self.currentSide + 2 * Self.horizontalInset
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                // A strip wider than the cap never fits, so a long one isn't measured whole.
                if naturalWidth <= ReadableWidth.filmstrip {
                    ViewThatFits(in: .horizontal) {
                        strip(lazy: false)
                        scrollingStrip
                    }
                } else {
                    scrollingStrip
                }
            }
            .onAppear {
                scrollToCurrent(proxy, animated: false)
            }
            .onChange(of: index) { _, _ in
                scrollToCurrent(proxy, animated: true)
            }
        }
        .frame(maxWidth: min(naturalWidth, ReadableWidth.filmstrip))
        .clipShape(.capsule)
        .glassEffect(.clear.interactive(), in: .capsule)
        .modifier(FilmstripGlassID(namespace: glassNamespace))
    }

    /// Lazy, so a moment of hundreds of photos requests only the thumbnails on screen. The
    /// height is the current thumbnail's even before it has been laid out.
    private var scrollingStrip: some View {
        ScrollView(.horizontal) {
            strip(lazy: true)
        }
        .scrollIndicators(.hidden)
    }

    private func strip(lazy: Bool) -> some View {
        Group {
            if lazy {
                LazyHStack(spacing: Self.spacing) {
                    thumbnails
                }
                .frame(minHeight: Self.currentSide)
            } else {
                HStack(spacing: Self.spacing) {
                    thumbnails
                }
            }
        }
        .padding(.vertical, Self.verticalInset)
        .padding(.horizontal, Self.horizontalInset)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: index)
    }

    private var thumbnails: some View {
        ForEach(photos.enumerated(), id: \.element) { position, id in
            thumbnail(id, at: position)
        }
    }

    private func thumbnail(_ id: PhotoID, at position: Int) -> some View {
        let isCurrent = position == index
        let side = isCurrent ? Self.currentSide : Self.thumbnailSide
        let shape = RoundedRectangle(cornerRadius: isCurrent ? 10 : Theme.Radius.thumbnail, style: .continuous)
        let state = badge(id)
        return Button {
            index = position
        } label: {
            ThumbnailView(id: id, size: .filmstrip)
                .frame(width: side, height: side)
                .clipShape(shape)
                .overlay {
                    if isCurrent {
                        shape.strokeBorder(Theme.Palette.onPhoto, lineWidth: 2)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if state == .kept {
                        FilmstripBadge(systemImage: "checkmark.circle.fill", tint: Theme.Palette.keep)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if state == .willDelete {
                        FilmstripBadge(systemImage: "trash.circle.fill", tint: Theme.Palette.delete)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .contentShape(.hoverEffect, shape)
        .hoverEffect(.highlight)
        .accessibilityLabel(Text(PhotoAccessibility.label(
            index: position,
            total: photos.count,
            captured: nil,
            isProtected: state == .protected,
            isKept: state == .kept
        )))
        .accessibilityValue(state == .willDelete
            ? Text("To delete", comment: "VoiceOver value of a photo that will be deleted.")
            : Text(verbatim: ""))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .id(id)
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        guard photos.indices.contains(index) else { return }
        let id = photos[index]
        withAnimation(animated && !reduceMotion ? .snappy : nil) {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

/// A small solid badge on a filmstrip thumbnail: a white glyph on a tinted circle.
private struct FilmstripBadge: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .symbolRenderingMode(.palette)
            .foregroundStyle(Theme.Palette.onPhoto, tint)
            .font(.caption2)
            .dynamicTypeSize(...DynamicTypeSize.large)
            .shadow(color: Theme.Palette.onPhotoShadow, radius: 1, y: 0.5)
            .padding(2)
            .accessibilityHidden(true)
    }
}

/// Joins the morphing group when the strip sits in a `GlassEffectContainer`.
private struct FilmstripGlassID: ViewModifier {
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.glassEffectID("filmstrip", in: namespace)
        } else {
            content
        }
    }
}
