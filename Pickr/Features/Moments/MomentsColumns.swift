import PickrCore
import PickrModels
import PickrPersistence
import SwiftUI

/// The Moments tab's column container (ADAPTIVE §3.2): the iPhone stack, or the list beside
/// Review, chosen from the tab's own width and size class (`ColumnLayout`).
///
/// - **Stack:** `NavigationStack(path: router.momentsPath)` with `MomentsScreen` at the root
///   and Review pushed. The bottom accessory (RootView) belongs to this layout.
/// - **Split:** `NavigationSplitView` (`.balanced`), the list as a 300–420 pt sidebar that
///   highlights the moment under review, and the detail showing Review or, with nothing
///   under review, `ReviewStartView`. The detail owns the tab's ambient background.
/// - The layout is reported to RootView through `layout`. Everything that must survive a
///   swap lives here or in the models: the list's scroll anchor and focused moment, the split
///   visibility, the banner's dismissal, the zoom namespace. One toast host on the trailing
///   column of either layout.
/// - Settings is presented here, above the switch, from `router.sheet`, so a swap doesn't
///   close it. Adjust is presented from its toolbar button (`adjustPresentation`,
///   GroupingSheet.swift): the sheet in the stack, a popover in the split.
struct MomentsColumns: View {
    @Binding var layout: ColumnLayout

    @Environment(LibraryModel.self) private var library
    @Environment(Router.self) private var router

    @Namespace private var zoomNamespace
    @State private var listAnchor: MomentID? = nil
    @State private var focusedMoment: MomentID? = nil
    @State private var splitVisibility: NavigationSplitViewVisibility = .all
    @State private var bannerDismissed = false

    init(layout: Binding<ColumnLayout>) {
        _layout = layout
    }

    var body: some View {
        ColumnLayoutReader(showsList: library.showsMomentList) { layout in
            columns(for: layout)
                .onChange(of: layout, initial: true) { _, newLayout in
                    if self.layout != newLayout { self.layout = newLayout }
                }
        }
        .sheet(isPresented: settingsSheet) {
            SettingsSheet()
                .presentationDetents([.large])
                .presentationSizing(.form)
                .zoomTransition(sourceID: MomentsTransitionID.settings, in: zoomNamespace)
        }
    }

    @ViewBuilder
    private func columns(for layout: ColumnLayout) -> some View {
        switch layout {
        case .stack:
            stack
        case .split:
            split
        }
    }

    private var stack: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.momentsPath) {
            MomentsScreen(
                selection: nil,
                anchor: $listAnchor,
                focusedMoment: $focusedMoment,
                bannerDismissed: $bannerDismissed,
                namespace: zoomNamespace
            )
            .navigationDestination(for: Router.MomentsRoute.self) { _ in
                HeldReviewScreen(namespace: zoomNamespace)
            }
        }
        .toastHost(isRaised: router.review != nil)
    }

    private var split: some View {
        @Bindable var router = router
        return NavigationSplitView(columnVisibility: $splitVisibility) {
            MomentsScreen(
                selection: $router.reviewSelection,
                anchor: $listAnchor,
                focusedMoment: $focusedMoment,
                bannerDismissed: $bannerDismissed,
                namespace: zoomNamespace
            )
            .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            MomentsDetail(focusedMoment: $focusedMoment, namespace: zoomNamespace)
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - Presentations (router.sheet is the single source)

    private var settingsSheet: Binding<Bool> {
        Binding {
            router.sheet == .settings
        } set: { isPresented in
            guard !isPresented, router.sheet == .settings else { return }
            router.sheet = nil
        }
    }
}

// MARK: - Detail column

/// The split's detail: Review while a moment is under review, otherwise the start view over
/// the list's background (the sidebar's focused moment). Review paints its own background from
/// the same session state. The two cross-fade, like moments selected in the sidebar.
private struct MomentsDetail: View {
    @Binding var focusedMoment: MomentID?
    let namespace: Namespace.ID

    @Environment(Router.self) private var router

    var body: some View {
        let isReviewing = router.review != nil
        NavigationStack {
            ZStack {
                if isReviewing {
                    HeldReviewScreen(namespace: namespace)
                        .transition(.opacity)
                } else {
                    ReviewStartView()
                        .modifier(MomentsListAmbient(focusedMoment: $focusedMoment, isEnabled: true))
                        .transition(.opacity)
                }
            }
            .animation(Motion.crossFade, value: isReviewing)
        }
        .toastHost(isRaised: isReviewing)
    }
}

// MARK: - Review destination

/// Review for `router.review`, holding on to the session it showed last, so the stack's
/// pop animation after the queue ends never shows an empty frame.
private struct HeldReviewScreen: View {
    let namespace: Namespace.ID

    @Environment(Router.self) private var router
    @State private var held: ReviewSession? = nil

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

#if DEBUG
#Preview("Columns: stack") {
    MomentsPreviewHost(.moments) {
        MomentsColumns(layout: .constant(.stack))
    }
}

#Preview("Columns: split", traits: .fixedLayout(width: 1180, height: 820)) {
    MomentsPreviewHost(.moments) {
        MomentsColumns(layout: .constant(.split))
    }
    .environment(\.horizontalSizeClass, .regular)
}

#Preview("Columns: split, dark", traits: .fixedLayout(width: 1180, height: 820)) {
    MomentsPreviewHost(.limited) {
        MomentsColumns(layout: .constant(.split))
    }
    .environment(\.horizontalSizeClass, .regular)
    .preferredColorScheme(.dark)
}
#endif
