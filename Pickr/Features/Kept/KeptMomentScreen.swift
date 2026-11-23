import PickrCore
import PickrModels
import SwiftUI
import UIKit

/// A kept moment, read-only (§3.3 S8b, COPY.md): the same **All** / **One by One** viewer as
/// Review, with no keep marks and no badges except favorites' hearts.
///
/// - **All:** `PhotoGrid` (columns from its own width). A tap opens the photo in One by One;
///   long press offers Show Photo Again and View; VoiceOver gets both as actions.
/// - **One by One:** `PhotoPager` under the bars with WP8's `Filmstrip` (unchanged) below; a
///   tap hides the bars and the filmstrip. The ⋯ menu has Show Photo Again for the photo shown.
/// - **Show Moment Again** is the screen's one prominent action. It closes the moment: the stack
///   pops, the split shows "Choose a moment". Both Show Again actions have Undo (`Curator`).
/// - Stack: pushed with a zoom from the card, tab bar hidden. Split: the detail column, tab bar
///   and status bar stay. It paints its own background, a photo blurred: in All the tile under
///   the grid's focus line, in One by One the photo shown; in a split it extends under the
///   sidebar.
/// - Mode and photo index live in `KeptBoard`, so a resize or fold keeps them.
struct KeptMomentScreen: View {
    /// The moment as it is now.
    let moment: Moment
    /// The ID the moment was opened with (the route); stable while its photos change.
    let routeID: MomentID

    @Environment(KeptBoard.self) private var board
    @Environment(Router.self) private var router
    @Environment(SettingsModel.self) private var settings
    @Environment(\.curator) private var curator
    @Environment(\.columnLayout) private var layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    @State private var chromeHidden = false
    /// The All grid's tile under the focus line, for the background.
    @State private var gridFocus = ScrollFocus<PhotoID>()

    var body: some View {
        @Bindable var board = self.board
        let index = currentIndex
        let isStack = layout == .stack
        let showsProtection = settings.protectFavorites

        ZStack {
            Group {
                switch board.mode {
                case .grid:
                    KeptMomentGrid(
                        moment: moment,
                        currentIndex: index,
                        showsProtection: showsProtection,
                        focus: gridFocus,
                        onView: { position in
                            board.singleIndex = position
                            board.mode = .single
                        },
                        onShowAgain: showPhotoAgain
                    )
                    .transition(.opacity)
                case .single:
                    KeptMomentSingle(
                        moment: moment,
                        index: currentIndexBinding,
                        chromeHidden: chromeHidden,
                        showsProtection: showsProtection,
                        onTap: toggleChrome
                    )
                    .transition(.opacity)
                }
            }
            .id(routeID)
            .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toastsStayAbove(.bottom)
        .animation(reduceMotion ? Motion.reducedFade : Motion.crossFade, value: routeID)
        .animation(Motion.crossFade, value: board.mode)
        .modifier(KeptMomentAmbient(
            moment: moment,
            shownPhoto: board.mode == .single ? moment.photos[index].id : nil,
            focus: gridFocus
        ))
        .navigationTitle(moment.start.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(subtitle(index: index))
        .toolbar {
            ToolbarItem(placement: .topBarPinnedTrailing) {
                KeptModePicker(mode: $board.mode)
            }
            // The tabs picker brings its own glass; the bar's shared glass drew a second outline.
            .sharedBackgroundVisibility(.hidden)
            if board.mode == .single {
                ToolbarItem(placement: .bottomBar) {
                    Menu {
                        Button {
                            showPhotoAgain(moment.photos[currentIndex].id)
                        } label: {
                            Label {
                                Text("Show Photo Again", comment: "Kept moment: put the photo shown back in Moments.")
                            } icon: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                        }
                    } label: {
                        Label {
                            Text("More", comment: "VoiceOver label of the Kept moment's ⋯ menu.")
                        } icon: {
                            Image(systemName: "ellipsis")
                        }
                    }
                }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button(action: showMomentAgain) {
                    Text("Show Moment Again", comment: "Kept moment: put every photo of this moment back in Moments.")
                }
                .buttonStyle(.glassProminent)
                .accessibilityHint(Text(
                    "It will show up in Moments again.",
                    comment: "VoiceOver hint of Show Moment Again. Also the toast after Show Again took a moment or a photo out of the Kept tab (shown with an Undo button): keep both the same."
                ))
            }
            .visibilityPriority(.high)
        }
        // The tab bar comes back as soon as the moment starts closing, not after the zoom settles.
        .toolbarVisibility(isStack && !router.keptPath.isEmpty ? .hidden : .automatic, for: .tabBar)
        .toolbarVisibility(chromeHidden ? .hidden : .automatic, for: .navigationBar, .bottomBar)
        .toolbarVisibility(chromeHidden && isStack ? .hidden : .automatic, for: .statusBar)
        .onChange(of: routeID) { _, _ in
            showChrome()
        }
        .onChange(of: board.mode) { _, _ in
            showChrome()
        }
        .onChange(of: voiceOverEnabled) { _, isEnabled in
            if isEnabled { showChrome() }
        }
    }

    // MARK: - State

    /// The photo One by One shows, clamped to the moment as it is now.
    private var currentIndex: Int {
        min(max(board.singleIndex, 0), moment.count - 1)
    }

    private var currentIndexBinding: Binding<Int> {
        let board = self.board
        let last = moment.count - 1
        return Binding(
            get: { min(max(board.singleIndex, 0), last) },
            set: { board.singleIndex = min(max($0, 0), last) }
        )
    }

    private func subtitle(index: Int) -> String {
        switch board.mode {
        case .grid:
            KeptLabels.gridSubtitle(photoCount: moment.count, isPicked: board.isPicked(moment.id))
        case .single:
            KeptLabels.singleSubtitle(captured: moment.photos[index].created, index: index, count: moment.count)
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

    /// Show Photo Again: one photo, with Undo. The last photo closes the moment.
    private func showPhotoAgain(_ id: PhotoID) {
        guard let curator, moment.photoIDs.contains(id) else { return }
        guard moment.count > 1 else {
            close { curator.restore([id]) }
            return
        }
        curator.restore([id])
        board.didShowAgain()
    }

    /// Show Moment Again: the whole moment, with Undo; closes it.
    private func showMomentAgain() {
        guard let curator else { return }
        let ids = moment.photoIDs
        close { curator.restore(ids) }
    }

    /// Shows the moment again and closes it. Its card leaves the list now, not at the next
    /// computation: in the stack the zoom back then falls back to the system's instead of
    /// landing on a card that vanishes after it; in a split the row visibly leaves.
    private func close(showingAgain restore: () -> Void) {
        withAnimation(layout == .split && !reduceMotion ? Motion.listChange : nil) {
            board.dismiss(moment.id)
            restore()
            board.didShowAgain()
            router.keptPath = []
        }
    }
}

// MARK: - All

/// The kept moment's photos in a read-only `PhotoGrid`.
private struct KeptMomentGrid: View {
    /// Passed into context-menu previews, which iOS hosts outside this view's environment.
    @Environment(\.imageLoader) private var previewLoader
    let moment: Moment
    /// The photo One by One showed last; the grid starts there.
    let currentIndex: Int
    let showsProtection: Bool
    let focus: ScrollFocus<PhotoID>
    let onView: (Int) -> Void
    let onShowAgain: (PhotoID) -> Void

    @State private var position: PhotoID?

    var body: some View {
        let photos = moment.photos
        PhotoGrid(photos: moment.photoIDs, position: $position, focus: focus) { index, id in
            PhotoTile(record: photos[index], index: index, total: photos.count, showsProtection: showsProtection)
                .onTapGesture { onView(index) }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text("Shows the photo.", comment: "VoiceOver hint of a photo tile in a kept moment."))
                .accessibilityAction { onView(index) }
                .accessibilityAction(named: Text("Show Photo Again", comment: "Kept moment: put this photo back in Moments.")) {
                    onShowAgain(id)
                }
                .contextMenu {
                    Button {
                        onShowAgain(id)
                    } label: {
                        Label {
                            Text("Show Photo Again", comment: "Kept moment: put this photo back in Moments.")
                        } icon: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                    }
                    Button {
                        onView(index)
                    } label: {
                        Label {
                            Text("View", comment: "Kept moment: show this photo in One by One.")
                        } icon: {
                            Image(systemName: "eye")
                        }
                    }
                } preview: {
                    KeptPhotoPreview(id: id)
                        .environment(\.imageLoader, previewLoader)
                }
        }
        .onAppear {
            // Back from One by One: start at the photo shown there.
            if currentIndex > 0, moment.photos.indices.contains(currentIndex) {
                position = moment.photos[currentIndex].id
            }
        }
    }
}

// MARK: - One by One

/// One photo at a time: the pager under the bars and the filmstrip below it, read-only.
private struct KeptMomentSingle: View {
    let moment: Moment
    @Binding var index: Int
    let chromeHidden: Bool
    let showsProtection: Bool
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let photos = moment.photos
        let protected = showsProtection ? moment.protectedIDs : []
        let badge: (PhotoID) -> PagerBadge = { protected.contains($0) ? .protected : .none }

        PhotoPager(
            photos: moment.photoIDs,
            index: $index,
            badge: badge,
            accessibilityLabel: { position in
                guard photos.indices.contains(position) else { return "" }
                let photo = photos[position]
                return PhotoAccessibility.label(
                    index: position,
                    total: photos.count,
                    captured: photo.created,
                    isProtected: protected.contains(photo.id)
                )
            },
            onTap: onTap
        )
        .ignoresSafeArea(.container, edges: .vertical)
        .safeAreaBar(edge: .bottom) {
            if !chromeHidden {
                Filmstrip(photos: moment.photoIDs, index: $index, badge: badge)
                    .frame(maxWidth: ReadableWidth.filmstrip)
                    .fixedSize(horizontal: false, vertical: true)
                    .toastsStayAbove(.top)
                    .hiddenInCompactHeight()
                    .padding(.horizontal, Theme.Spacing.large)
                    .padding(.bottom, Theme.Spacing.small)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}

// MARK: - Pieces

/// The background (blueprint §3.5): the photo One by One shows, or in All the photo under the
/// grid's focus line. A modifier, so a scroll that moves the focus re-renders only this.
private struct KeptMomentAmbient: ViewModifier {
    let moment: Moment
    /// One by One: the photo shown. `nil` in All.
    let shownPhoto: PhotoID?
    let focus: ScrollFocus<PhotoID>

    func body(content: Content) -> some View {
        content.ambientBackground(.photo(shownPhoto ?? focus.photo(in: moment)))
    }
}

/// The **All** / **One by One** picker, pinned at the top trailing edge.
private struct KeptModePicker: View {
    @Binding var mode: KeptBoard.Mode

    var body: some View {
        Picker(selection: $mode) {
            Label {
                Text("All", comment: "Kept moment: see every photo of the moment at once.")
            } icon: {
                Image(systemName: "square.grid.2x2")
            }
            .tag(KeptBoard.Mode.grid)
            Label {
                Text("One by One", comment: "Kept moment: see the photos one at a time.")
            } icon: {
                Image(systemName: "photo")
            }
            .tag(KeptBoard.Mode.single)
        } label: {
            Text("View", comment: "VoiceOver label of the Kept moment's All / One by One picker.")
        }
        .pickerStyle(.tabs)
        .labelStyle(.iconOnly)
        .fixedSize()
    }
}

/// The long-press preview of one photo: the tile image at once, then a sharper one, whole.
private struct KeptPhotoPreview: View {
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

/// The words the Kept moment shows (COPY.md), from plain values.
nonisolated enum KeptLabels {
    /// All: "5 photos · Kept", or "5 photos · Picked by you" in Photos you picked.
    static func gridSubtitle(photoCount: Int, isPicked: Bool) -> String {
        joined([
            String(localized: "\(photoCount) photos", comment: "Kept moment subtitle in All: the number of photos."),
            isPicked
                ? String(localized: "Picked by you", comment: "Kept moment subtitle: the photos were kept while the rest of their moment was deleted.")
                : String(localized: "Kept", comment: "Kept moment subtitle: the moment was kept with Keep All."),
        ])
    }

    /// One by One: "13:25:08 · 2 of 5".
    static func singleSubtitle(captured: Date, index: Int, count: Int) -> String {
        joined([
            captured.formatted(date: .omitted, time: .standard),
            String(
                localized: "\(index + 1) of \(count)",
                comment: "Kept moment subtitle in One by One: the photo's place in the moment. 1: position, 2: number of photos."
            ),
        ])
    }

    private static func joined(_ parts: [String]) -> String {
        parts.joined(separator: String(localized: " · ", comment: "Separator between the parts of a subtitle."))
    }
}
