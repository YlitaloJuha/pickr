import PickrCore
import PickrModels
import SwiftUI
import TipKit

/// Review in One by One (§3.3 S4 Single mode, ADAPTIVE S4, §6.2): one photo at a time.
///
/// - `PhotoPager` runs under the bars (vertical edges only) and stays clear, so
///   `ReviewScreen`'s blurred-photo background shows around the photo.
/// - Swipe sideways to page, swipe up to keep (the Keep toggle is the visible alternative),
///   pinch to peek, double-tap to zoom, single tap to hide the controls and bars.
/// - The filmstrip and the Keep toggle float in clear glass over the photo, in one
///   `GlassEffectContainer`, so the toggle morphs when its state changes. With a compact
///   height only the Keep toggle remains.
struct ReviewSingle: View {
    let moment: Moment
    /// The photos marked to keep (the session's, or the last ones while Review pops).
    let kept: Set<PhotoID>
    /// The photo shown: the session's `singleIndex`, or a constant while Review pops.
    @Binding var index: Int
    /// The controls, bars and (in the stack) status bar are hidden.
    let chromeHidden: Bool
    /// A single tap on the photo.
    let onTap: () -> Void
    /// Keep or unkeep the photo at this index (swipe up, the Keep toggle, VoiceOver), with
    /// the keep haptic.
    let onKeep: (Int) -> Void
    /// The top of the bottom bar's buttons in window coordinates, or `nil` while unknown.
    let bottomBarTop: CGFloat?

    @Environment(SettingsModel.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Namespace private var glassNamespace

    private let swipeTip = SwipeUpKeepTip()
    /// Extra room under the filmstrip where the bottom bar floats over the content without
    /// reserving safe area (the open iPhone Duo's detail column); 0 elsewhere.
    @State private var lift: CGFloat = 0

    var body: some View {
        let photos = moment.photos
        let hasKept = photos.contains { kept.contains($0.id) }
        let showsProtection = settings.protectFavorites
        let protected = showsProtection ? moment.protectedIDs : []
        let badge: (PhotoID) -> PagerBadge = { id in
            if kept.contains(id) { return .kept }
            if hasKept { return .willDelete }
            return protected.contains(id) ? .protected : .none
        }
        let currentID = photos.indices.contains(index) ? photos[index].id : nil

        PhotoPager(
            photos: moment.photoIDs,
            index: $index,
            badge: badge,
            accessibilityLabel: { index in
                guard photos.indices.contains(index) else { return "" }
                let photo = photos[index]
                return PhotoAccessibility.label(
                    index: index,
                    total: photos.count,
                    captured: photo.created,
                    isProtected: protected.contains(photo.id),
                    isKept: kept.contains(photo.id)
                )
            },
            onSwipeUp: { onKeep(index) },
            onTap: onTap,
            onKeepAction: { index in onKeep(index) }
        )
        .ignoresSafeArea(.container, edges: .vertical)
        .safeAreaBar(edge: .bottom) {
            if !chromeHidden {
                GlassEffectContainer(spacing: Theme.Spacing.medium) {
                    HStack(spacing: Theme.Spacing.medium) {
                        Filmstrip(
                            photos: moment.photoIDs,
                            index: $index,
                            badge: badge,
                            glassNamespace: glassNamespace
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .hiddenInCompactHeight()

                        KeepToggle(isKept: currentID.map(kept.contains) ?? false, glassNamespace: glassNamespace) {
                            onKeep(index)
                        }
                        .fixedSize()
                        .popoverTip(swipeTip, arrowEdge: .bottom)
                    }
                }
                .toastsStayAbove(.top)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { maxY in
                    updateLift(rowBottom: maxY)
                }
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.bottom, Theme.Spacing.small + lift)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    /// Raises the row until it clears the bar's buttons. The row is measured with the current
    /// lift applied, so the lift settles at exactly the overlap and drops back when there is none.
    private func updateLift(rowBottom: CGFloat) {
        guard let bottomBarTop else {
            if lift != 0 { lift = 0 }
            return
        }
        let needed = max(0, lift + rowBottom - (bottomBarTop - Theme.Spacing.small))
        if abs(needed - lift) > 0.5 { lift = needed }
    }
}
