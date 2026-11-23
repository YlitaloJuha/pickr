import PickrCore
import PickrModels
import SwiftUI
import TipKit

/// Review (§3.3 S4, ADAPTIVE S4): the session's current moment in All or One by One, with the
/// bottom bar that commits it and moves on.
///
/// - **Containers.** Stack: pushed with a zoom from the moment's card (a cross-fade under
///   Reduce Motion) and the tab bar hidden. Split: the detail column, no push transition, tab
///   bar visible, status bar never hidden, and moment changes cross-fade. `\.columnLayout`
///   decides those four things only (plus Esc leaving Review, which only the stack can do).
/// - **Moving on** (blueprint §3.6). Commit, Keep All, Delete All and Skip advance the same
///   session; the next moment slides in from the trailing edge, Previous Moment from the
///   leading edge, while the one it replaces fades. After the last one the Router ends the
///   review and posts the summary toast: the stack pops with the last moment frozen as it was
///   (no empty or reset frame), zooming back to the card the list scrolled to; the split shows
///   its start view. The models post every toast; this view adds the haptics, played by the
///   app (`CommandHaptics`) so they survive the screen going away with the last moment.
/// - **Chrome.** In One by One a tap hides the bars, the filmstrip and the Keep toggle (and the
///   status bar in the stack). They come back with another tap, on a new moment or mode, and
///   stay visible while VoiceOver runs. Toasts sit above the bar and the filmstrip.
/// - **Background.** A photo, blurred: in All the tile under the grid's focus line (the first
///   photo until the grid reports), in One by One the photo shown.
/// - **Keyboard.** Plain keys in `ReviewKeyHandling`; the Clean Up menu reads the focused
///   values published here.
struct ReviewScreen: View {
    let session: ReviewSession
    /// The zoom-transition namespace of the Moments list.
    let namespace: Namespace.ID

    @Environment(\.columnLayout) private var layout
    @Environment(Router.self) private var router
    @Environment(LibraryModel.self) private var library
    @Environment(SettingsModel.self) private var settings
    @Environment(CommandHaptics.self) private var appHaptics: CommandHaptics?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    @State private var chromeHidden = false
    /// The All focus ring's tile, or `nil` while hidden.
    @State private var ring: Int?
    @State private var gridColumns = PhotoGridLayout.minimumColumns
    @State private var bulkDelete: ReviewBulkDelete?
    /// Bumped for each keep or unkeep this screen makes (tap, swipe up, toggle, number key).
    @State private var keepToggles = 0
    /// The last frame shown, for the pop after the queue ended (the session is then empty).
    @State private var snapshot = ReviewSnapshot()
    /// The queue position the content shows, to tell moving on from Previous Moment.
    @State private var shownPosition: Int?
    /// Where the list scrolled when the queue ended: the zoom returns to that card.
    @State private var returnTarget: MomentID?
    /// The All grid's tile under the focus line, for the background.
    @State private var gridFocus = ScrollFocus<PhotoID>()
    @State private var tapTipDone = false
    @State private var swipeTipDone = false

    var body: some View {
        @Bindable var session = session
        let frame = currentFrame()
        let header = frame.map(header(for:))
        let isStack = layout == .stack
        let arrival = arrival(isStack: isStack)

        ZStack {
            if let frame {
                content(for: frame)
                    .id(frame.moment.id)
                    .transition(arrival.transition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toastsStayAbove(.bottom)
        .animation(arrival.animation(reduceMotion: reduceMotion), value: frame?.moment.id)
        .animation(Motion.crossFade, value: session.mode)
        .modifier(ReviewAmbient(session: session, focus: gridFocus))
        .navigationTitle(header?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(header?.subtitle ?? "")
        .toolbar {
            ToolbarItem(placement: .topBarPinnedTrailing) {
                Picker(selection: $session.mode) {
                    Label {
                        Text("All", comment: "Review: see every photo of the moment at once.")
                    } icon: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .tag(ReviewSession.Mode.grid)
                    Label {
                        Text("One by One", comment: "Review: see the photos one at a time.")
                    } icon: {
                        Image(systemName: "photo")
                    }
                    .tag(ReviewSession.Mode.single)
                } label: {
                    Text("View", comment: "VoiceOver label of Review's All / One by One picker.")
                }
                .pickerStyle(.tabs)
                .labelStyle(.iconOnly)
                // Its own width, not the whole bar's: in a wide detail column it stretched and
                // cut off the title.
                .fixedSize()
            }
            // The tabs picker brings its own glass; the bar's shared glass around it drew a
            // second outline.
            .sharedBackgroundVisibility(.hidden)
            ReviewBottomBar(
                session: session,
                state: frame?.bar ?? ReviewBarState(session: session, protectFavorites: settings.protectFavorites),
                bulkDelete: $bulkDelete,
                onCommit: commit,
                onSkip: session.skip,
                onKeepAll: keepAll,
                onDeleteAll: requestDeleteAll,
                onConfirmDeleteAll: confirmDeleteAll
            )
        }
        // The tab bar comes back as soon as Review starts closing (the router has let go of the
        // session while this screen is held for the pop), not after the zoom has settled.
        .toolbarVisibility(isStack && router.review != nil ? .hidden : .automatic, for: .tabBar)
        .toolbarVisibility(chromeHidden ? .hidden : .automatic, for: .navigationBar, .bottomBar)
        .toolbarVisibility(chromeHidden && isStack ? .hidden : .automatic, for: .statusBar)
        .modifier(ReviewKeyHandling(
            session: session,
            canLeave: isStack,
            ring: $ring,
            columns: gridColumns,
            onLeave: router.endReview,
            onToggled: didToggleKeep
        ))
        .focusedSceneValue(\.reviewSession, session)
        .focusedSceneValue(\.reviewKeepTarget, keepTarget)
        .hapticFeedback(.keepToggled, trigger: keepToggles)
        .modifier(ReviewPushTransition(
            isEnabled: isStack,
            sourceID: session.current?.id ?? router.scrollTarget ?? returnTarget ?? frame?.moment.id,
            namespace: namespace
        ))
        .onChange(of: frame?.moment.id) { _, _ in
            ring = nil
            showChrome()
            bulkDelete = nil
        }
        .onChange(of: session.position, initial: true) { _, position in
            shownPosition = position
        }
        .onChange(of: router.scrollTarget) { _, target in
            // The list clears it once it has scrolled; the pop may still be looking for it.
            if let target { returnTarget = target }
        }
        .onChange(of: session.mode) { _, _ in
            ring = nil
            showChrome()
        }
        .onChange(of: voiceOverEnabled) { _, isEnabled in
            if isEnabled { showChrome() }
        }
    }

    @ViewBuilder
    private func content(for frame: ReviewFrame) -> some View {
        @Bindable var session = session
        switch session.mode {
        case .grid:
            ReviewGrid(
                session: session,
                moment: frame.moment,
                kept: frame.kept,
                ring: ring,
                onTap: { id in
                    ring = nil
                    session.toggle(id)
                    didToggleKeep()
                },
                onDragToggle: { id in
                    ring = nil
                    session.toggle(id)
                    invalidateTapTip()
                },
                onLayoutChange: { gridColumns = $0.columns },
                focus: gridFocus
            )
            .transition(.opacity)
        case .single:
            ReviewSingle(
                moment: frame.moment,
                kept: frame.kept,
                index: session.current == nil ? .constant(frame.index) : $session.singleIndex,
                chromeHidden: chromeHidden,
                onTap: toggleChrome,
                onKeep: { index in
                    session.togglePhoto(at: index)
                    didToggleKeep()
                    if !swipeTipDone {
                        swipeTipDone = true
                        SwipeUpKeepTip().invalidate(reason: .actionPerformed)
                    }
                }
            )
            .transition(.opacity)
        }
    }

    // MARK: - Frame, header, keyboard target

    /// The session's moment with its marks, photo and bar; once the queue has ended, the last
    /// one as it was, so the pop never animates an empty or reset frame. The snapshot is a plain
    /// reference, so keeping it up to date doesn't invalidate the view.
    private func currentFrame() -> ReviewFrame? {
        guard let moment = session.current else { return snapshot.frame }
        let frame = ReviewFrame(
            moment: moment,
            kept: session.selection.kept,
            index: session.singleIndex,
            bar: ReviewBarState(session: session, protectFavorites: settings.protectFavorites)
        )
        snapshot.frame = frame
        return frame
    }

    /// How the next moment arrives: moving on and Previous Moment slide in the stack (the queue
    /// position tells which); a split, Reduce Motion or a change in place cross-fade.
    private func arrival(isStack: Bool) -> MomentArrival {
        guard isStack, !reduceMotion, let shownPosition else { return .fade }
        if session.position > shownPosition { return .forward }
        if session.position < shownPosition { return .backward }
        return .fade
    }

    private func header(for frame: ReviewFrame) -> ReviewHeader {
        let moment = frame.moment
        let title = moment.start.formatted(date: .abbreviated, time: .omitted)
        switch session.mode {
        case .grid:
            return ReviewHeader(title: title, subtitle: ReviewLabels.gridSubtitle(
                photoCount: moment.count,
                start: moment.start,
                end: moment.end,
                position: session.position,
                total: session.total
            ))
        case .single:
            let index = moment.photos.indices.contains(frame.index) ? frame.index : 0
            let photo = moment.photos[index]
            return ReviewHeader(title: title, subtitle: ReviewLabels.singleSubtitle(
                captured: photo.created,
                bytes: library.sizes[photo.id],
                index: index,
                count: moment.count
            ))
        }
    }

    private var keepTarget: PhotoID? {
        guard let moment = session.current else { return nil }
        switch session.mode {
        case .single:
            return session.currentPhoto?.id
        case .grid:
            guard let ring, moment.photos.indices.contains(ring) else { return nil }
            return moment.photos[ring].id
        }
    }

    // MARK: - Actions

    private func toggleChrome() {
        guard !voiceOverEnabled else { return }
        withAnimation(Motion.chrome) {
            chromeHidden.toggle()
        }
    }

    private func showChrome() {
        guard chromeHidden else { return }
        withAnimation(Motion.chrome) {
            chromeHidden = false
        }
    }

    private func didToggleKeep() {
        keepToggles &+= 1
        invalidateTapTip()
    }

    private func invalidateTapTip() {
        guard !tapTipDone else { return }
        tapTipDone = true
        TapToKeepTip().invalidate(reason: .actionPerformed)
    }

    /// Delete 4 Photos, or Keep All & Next. Started in a `Task`, never in `.task`, so a
    /// container swap while the system dialog is up can't cancel it.
    private func commit() {
        guard session.canCommit else { return }
        let session = session
        let haptics = appHaptics
        Task {
            haptics?.play(for: await session.commit())
        }
    }

    private func keepAll() {
        guard session.canMoveOn else { return }
        session.keepAside()
        appHaptics?.play(.keptAside)
    }

    private func requestDeleteAll() {
        guard session.canMoveOn, session.canDeleteWhole, let moment = session.current else { return }
        if session.needsBulkConfirmation {
            bulkDelete = ReviewBulkDelete(momentID: moment.id, count: session.deletableCount)
        } else {
            deleteAll()
        }
    }

    private func confirmDeleteAll(_ request: ReviewBulkDelete) {
        // The moment may have changed while the dialog was up.
        guard session.current?.id == request.momentID else { return }
        deleteAll()
    }

    private func deleteAll() {
        guard session.canMoveOn else { return }
        let session = session
        let haptics = appHaptics
        Task {
            haptics?.play(for: await session.deleteWhole())
        }
    }
}

/// What Review's content shows: a moment, its marks, the photo One by One shows and the bar.
private struct ReviewFrame {
    let moment: Moment
    let kept: Set<PhotoID>
    let index: Int
    let bar: ReviewBarState
}

private final class ReviewSnapshot {
    var frame: ReviewFrame?
}

/// How a new moment's content arrives (blueprint §3.6). The one it replaces always just fades,
/// so the removal never depends on a direction decided before the move.
private enum MomentArrival {
    case forward, backward, fade

    var transition: AnyTransition {
        switch self {
        case .forward: .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity)
        case .backward: .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity)
        case .fade: .opacity
        }
    }

    func animation(reduceMotion: Bool) -> Animation {
        switch self {
        case .forward, .backward: Motion.advance
        case .fade: reduceMotion ? Motion.reducedFade : Motion.crossFade
        }
    }
}

extension ReviewScreen {
    /// The `.review` route's destination (and the split's detail): shows `router.review`,
    /// and keeps showing the same session while the stack pops after the Router ended it.
    static func destination(namespace: Namespace.ID) -> some View {
        HeldReview(namespace: namespace)
    }
}

/// Holds the review it was built with, so the pop animation never shows an empty frame.
private struct HeldReview: View {
    let namespace: Namespace.ID

    @Environment(Router.self) private var router
    @State private var held: ReviewSession?

    var body: some View {
        ZStack {
            if let session = router.review ?? held {
                ReviewScreen(session: session, namespace: namespace)
                    .id(session.id)
            }
        }
        .onChange(of: router.review?.id, initial: true) { _, _ in
            if let review = router.review { held = review }
        }
    }
}

/// Review's background (blueprint §3.5): in All the photo under the grid's focus line, in One by
/// One the photo shown. A modifier, so a scroll that moves the focus re-renders only the
/// background. Keeps the last photo while the screen pops after the queue ended.
private struct ReviewAmbient: ViewModifier {
    let session: ReviewSession
    let focus: ScrollFocus<PhotoID>

    @State private var last: AmbientSource = .plain

    func body(content: Content) -> some View {
        let source = session.current.map(source(for:)) ?? last
        content
            .ambientBackground(source)
            .onChange(of: source, initial: true) { _, newSource in
                if session.current != nil { last = newSource }
            }
    }

    private func source(for moment: Moment) -> AmbientSource {
        if session.mode == .single, let photo = session.currentPhoto {
            return .photo(photo.id)
        }
        return .photo(focus.photo(in: moment))
    }
}

/// The title and subtitle of the navigation bar.
struct ReviewHeader: Equatable {
    let title: String
    let subtitle: String
}

/// The zoom from the moment's card in the stack (a cross-fade under Reduce Motion); nothing in
/// the split, where Review is the detail column rather than a push.
private struct ReviewPushTransition: ViewModifier {
    let isEnabled: Bool
    let sourceID: MomentID?
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if isEnabled, let sourceID {
            content.zoomTransition(sourceID: sourceID, in: namespace)
        } else {
            content
        }
    }
}
