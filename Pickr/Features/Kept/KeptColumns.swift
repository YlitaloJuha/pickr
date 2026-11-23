import PickrCore
import PickrModels
import PickrPersistence
import SwiftUI

/// The Kept tab's root (ADAPTIVE §3.2): the list and the Kept moment, as one column or side by
/// side, chosen from the tab's own width (`ColumnLayoutReader`).
///
/// - **Stack** (iPhone, narrow windows, compact width): `NavigationStack(path: router.keptPath)`
///   with the list at the root and the Kept moment pushed with a zoom from its card.
/// - **Split** (regular width, ≥ 740 pt, something kept): `NavigationSplitView`, the list in a
///   300–420 pt sidebar beside the Kept moment, or "Choose a moment". The list's selection is
///   `router.keptPath`, so the same path drives both layouts and a swap loses nothing.
/// - One toast host: on the stack, or on the split's detail column.
/// - Background: the screen on top paints it in the stack; in a split the detail column does
///   (the Kept moment's photo, or the list's) and the sidebar paints none.
/// - The sections are computed here, in `.task(id:)`, into the shared `KeptBoard`.
struct KeptColumns: View {
    @Environment(Router.self) private var router
    @Environment(KeptModel.self) private var kept
    @Environment(LibraryModel.self) private var library
    @Environment(SettingsModel.self) private var settings

    @State private var board: KeptBoard
    @State private var visibility: NavigationSplitViewVisibility = .all
    @Namespace private var namespace

    init() {
        board = KeptBoard()
    }

    #if DEBUG
    /// Previews start from a prepared board.
    init(board: KeptBoard) {
        self.board = board
    }
    #endif

    var body: some View {
        let inputs = KeptInputs(items: kept.items, index: library.index, window: settings.grouping.window)

        ColumnLayoutReader(showsList: board.showsList) { layout in
            switch layout {
            case .stack:
                stack
            case .split:
                split
            }
        }
        .environment(board)
        .hapticFeedback(.restored, trigger: board.showAgainCount)
        .task(id: inputs) {
            recompute(inputs)
        }
        .onChange(of: router.keptSelection, initial: true) { _, route in
            board.open(route)
        }
    }

    // MARK: - Containers

    private var stack: some View {
        @Bindable var router = self.router
        return NavigationStack(path: $router.keptPath) {
            KeptScreen(selection: nil, namespace: namespace)
                .navigationDestination(for: Router.KeptRoute.self) { route in
                    KeptMomentDestination(route: route, namespace: namespace)
                }
        }
        .toastHost(isRaised: !router.keptPath.isEmpty)
    }

    private var split: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            KeptScreen(selection: listSelection, namespace: namespace)
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            NavigationStack {
                KeptDetail()
            }
            .toastHost(isRaised: router.keptSelection != nil)
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// The sidebar's selection: the open moment (followed if its ID changed), written back to
    /// `router.keptPath`. Selecting the open moment again changes nothing.
    private var listSelection: Binding<MomentID?> {
        let router = self.router
        let board = self.board
        return Binding(
            get: { board.moment(for: router.keptSelection)?.id },
            set: { newValue in
                guard let newValue, newValue != board.moment(for: router.keptSelection)?.id else { return }
                router.keptSelection = newValue
            }
        )
    }

    // MARK: - Sections

    /// O(library): runs in the task, never in a body.
    private func recompute(_ inputs: KeptInputs) {
        let groups = kept.groups(index: inputs.index, window: inputs.window)
        let liveCount = kept.liveIDs(in: inputs.index).count
        let route = router.keptSelection
        board.update(aside: groups.aside, reviewed: groups.reviewed, liveCount: liveCount, route: route)
        // The open moment is gone (shown again elsewhere, deleted, hidden): close it.
        if route != nil, board.moment(for: route) == nil {
            router.keptPath = []
        }
    }
}

/// What the Kept sections are computed from. Unchanged arrays compare by identity first, so
/// the key costs little on every body evaluation.
private struct KeptInputs: Equatable {
    let items: [PhotoID: KeptItem]
    let index: [AssetRecord]
    let window: TimeWindow
}

// MARK: - Split detail

/// The split's detail column: the open Kept moment, or "Choose a moment" over the list's
/// background. The two cross-fade, like moments selected in the list.
private struct KeptDetail: View {
    @Environment(Router.self) private var router
    @Environment(KeptBoard.self) private var board

    var body: some View {
        let route = router.keptSelection
        let moment = board.moment(for: route)
        ZStack {
            if let route, let moment {
                KeptMomentScreen(moment: moment, routeID: route)
                    .transition(.opacity)
            } else {
                ContentUnavailableView {
                    Label {
                        Text("Choose a moment", comment: "Kept, side by side: the detail column while no moment is open.")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(KeptListAmbient())
                .transition(.opacity)
            }
        }
        .animation(Motion.crossFade, value: moment == nil)
    }
}

// MARK: - Stack destination

/// The pushed Kept moment. It keeps showing the moment it last had while the stack pops after
/// Show Moment Again, so the pop never animates an empty frame. The zoom follows the moment's
/// current ID (Show Photo Again can change it), so Back lands on its card; a moment that left
/// the list has no card, and the zoom falls back to the system's.
private struct KeptMomentDestination: View {
    let route: Router.KeptRoute
    let namespace: Namespace.ID

    @Environment(KeptBoard.self) private var board
    @State private var held: Moment?

    var body: some View {
        let routeID = route.momentID
        let moment = board.moment(for: routeID)
        ZStack {
            if let shown = moment ?? held {
                KeptMomentScreen(moment: shown, routeID: routeID)
            }
        }
        .zoomTransition(sourceID: (moment ?? held)?.id ?? routeID, in: namespace)
        .onChange(of: moment, initial: true) { _, newMoment in
            if let newMoment { held = newMoment }
        }
    }
}

extension Router.KeptRoute {
    /// The moment this route opens.
    var momentID: MomentID {
        switch self {
        case .keptMoment(let id): id
        }
    }
}

// MARK: - List background

/// Paints the list's background: with `strip`, the photo strip behind the list's rows (the
/// stack); otherwise the first photo of the moment under its focus line ("Choose a moment").
/// A modifier, so only this layer follows the list as it scrolls, not the list itself.
struct KeptListAmbient: ViewModifier {
    /// The list's rows, for the photo strip. `nil` for a single photo.
    var strip: ScrollFocus<MomentID>? = nil

    @Environment(KeptBoard.self) private var board

    func body(content: Content) -> some View {
        content.ambientBackground(board.listAmbient, strip: strip)
    }
}
