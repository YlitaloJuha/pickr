import PickrCore
import PickrModels
import SwiftUI
import UIKit

/// The Kept list (§3.3 S8, COPY.md): everything kept, as moments, in two sections.
///
/// - **Moments you kept** (Keep All, and the v1 list), then **Photos you picked** (the keepers
///   of a partial delete), collapsed until opened, with its footer. Cards show the date and
///   the count, no size. A footnote says when shown-again photos come back.
/// - **Swipe either way: Show Again**, at once, with an Undo toast from `Curator`. The context
///   menu has Show Again and View; VoiceOver gets both as actions.
/// - **⋯ → Show All Again…** asks first ("Show all 23 moments in Moments again?"); it is
///   available only while some kept photo is in the library (live IDs only).
/// - Stack: a tap pushes the Kept moment (zoom from the card); the list paints the photo strip
///   behind its rows. Split (`selection` set): a tap selects, the detail paints.
/// - Empty: "Nothing kept yet", capped to a readable width.
struct KeptScreen: View {
    /// The split's selection; `nil` in the stack, where a tap pushes instead.
    let selection: Binding<MomentID?>?
    /// The zoom-transition namespace shared with the pushed Kept moment.
    let namespace: Namespace.ID

    @Environment(KeptBoard.self) private var board
    @Environment(KeptModel.self) private var kept
    @Environment(LibraryModel.self) private var library
    @Environment(Router.self) private var router
    @Environment(\.curator) private var curator
    @Environment(\.openURL) private var openURL
    @Environment(\.hasFinishedLaunch) private var hasFinishedLaunch
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showAll: KeptShowAllRequest?
    /// This list's rows, for the strip and the focus (`KeptBoard.listFocus` keeps the focus
    /// across a swap).
    @State private var focus = ScrollFocus<MomentID>()

    var body: some View {
        let state = listState
        Group {
            switch state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .denied:
                noAccess(canAsk: false)
            case .notAsked:
                noAccess(canAsk: true)
            case .empty:
                empty
            case .list:
                list
            }
        }
        // Loading, empty and the list replace each other with a cross-fade.
        .animation(Motion.crossFade, value: state)
        .modifier(KeptScreenBackground(paints: selection == nil, strip: state == .list ? focus : nil))
        .navigationTitle(Text("Kept", comment: "Title of the Kept tab."))
        .toolbar {
            if state == .list {
                ToolbarItem(placement: .topBarTrailing) {
                    moreMenu
                }
            }
        }
    }

    // MARK: - States

    private enum ListState: Equatable {
        case loading, denied, notAsked, empty, list
    }

    private var listState: ListState {
        if library.access == .denied { return .denied }
        // Access reset in Settings after onboarding: the library is never read, so waiting
        // for it would spin forever. Before launch has read the access, it is only unknown.
        if library.access == .notDetermined, hasFinishedLaunch { return .notAsked }
        guard board.isLoaded else { return .loading }
        if !board.isEmpty { return .list }
        // Kept photos exist, but the library hasn't been read yet.
        let isReading: Bool = switch library.phase {
        case .idle, .indexing: true
        case .ready, .failed: false
        }
        return !kept.ids.isEmpty && isReading ? .loading : .empty
    }

    private var empty: some View {
        ContentUnavailableView {
            Label {
                Text("Nothing kept yet", comment: "Kept tab empty state: title.")
            } icon: {
                Image(systemName: "checkmark.circle")
            }
        } description: {
            Text(
                "Moments you keep show up here and won’t come back for cleanup.",
                comment: "Kept tab empty state: explanation."
            )
        }
        .readableWidth()
        .frame(maxHeight: .infinity)
    }

    /// Access is off (Open Settings), or was never asked (Continue shows the iOS prompt).
    private func noAccess(canAsk: Bool) -> some View {
        ContentUnavailableView {
            Label {
                Text("Pickr. needs your photos to find moments.", comment: "Shown while photo access is off.")
            } icon: {
                Image(systemName: "lock.shield")
            }
        } actions: {
            if canAsk {
                Button {
                    // A user action that must finish even if this view goes away.
                    Task { await library.requestAccess() }
                } label: {
                    Text("Continue", comment: "Onboarding: go to the next step.")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            } else {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Text("Open Settings", comment: "Opens the Settings app, where photo access can be turned on.")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
        }
        .readableWidth()
        .frame(maxHeight: .infinity)
    }

    // MARK: - List

    private var list: some View {
        @Bindable var board = self.board
        let isStack = selection == nil
        return List(selection: selection) {
            if !board.aside.isEmpty {
                Section {
                    ForEach(board.aside) { moment in
                        row(moment, isStack: isStack)
                    }
                } header: {
                    KeptSectionTitle(Text("Moments you kept", comment: "Kept tab: section of moments kept with Keep All."))
                }
            }
            if !board.reviewed.isEmpty {
                Section {
                    if board.reviewedExpanded {
                        ForEach(board.reviewed) { moment in
                            row(moment, isStack: isStack)
                        }
                    }
                    // A clear row, not a section footer: plain-list footers draw an opaque band
                    // over the ambient strip.
                    Text(
                        "Photos you kept while deleting the rest of their moment.",
                        comment: "Kept tab: footer of the Photos you picked section."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(Theme.Insets.cardRow)
                    .selectionDisabled()
                } header: {
                    KeptPickedHeader(photoCount: board.reviewedPhotoCount, isExpanded: $board.reviewedExpanded)
                }
            }
            Text(
                "Photos you show again come back to Moments only if they were taken close to another photo.",
                comment: "Kept tab: footnote under the list."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(Theme.Insets.cardRow)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .modifier(KeptReadableMargins(isEnabled: isStack))
        .scrollFocusContainer(focus)
        .onScrollFocusChange(focus) { id in
            if board.listFocus != id { board.listFocus = id }
        }
    }

    private func row(_ moment: Moment, isStack: Bool) -> some View {
        KeptMomentRow(
            moment: moment,
            opensOnTap: isStack,
            namespace: namespace,
            onOpen: { router.keptSelection = moment.id },
            onShowAgain: { showAgain(moment) },
            focus: focus
        )
    }

    // MARK: - ⋯ menu

    private var moreMenu: some View {
        Menu {
            Button {
                showAll = KeptShowAllRequest(moments: board.momentCount)
            } label: {
                Label {
                    Text("Show All Again…", comment: "Kept ⋯ menu: put every kept moment back in Moments (asks first).")
                } icon: {
                    Image(systemName: "arrow.counterclockwise")
                }
            }
            .disabled(board.liveCount == 0)
        } label: {
            Label {
                Text("More", comment: "VoiceOver label of the Kept tab's ⋯ menu.")
            } icon: {
                Image(systemName: "ellipsis")
            }
        }
        .confirmationDialog(
            Text(
                "Show all \(showAll?.moments ?? board.momentCount) moments in Moments again?",
                comment: "Show All Again confirmation title. 1: the number of kept moments."
            ),
            item: $showAll,
            titleVisibility: .visible
        ) { _ in
            Button {
                showAllAgain()
            } label: {
                Text("Show All Again", comment: "Show All Again confirmation: the confirming button.")
            }
        } message: { _ in
            Text("They can come back for cleanup.", comment: "Show All Again confirmation: explanation.")
        }
    }

    // MARK: - Actions

    /// Show Again on a card: the whole moment, with Undo (the toast is `Curator`'s). The row
    /// leaves with an animation as the toast comes in.
    private func showAgain(_ moment: Moment) {
        guard let curator else { return }
        let closesOpenMoment = board.moment(for: router.keptSelection)?.id == moment.id
        withAnimation(reduceMotion ? Motion.reducedFade : Motion.listChange) {
            board.dismiss(moment.id)
            curator.restore(moment.photoIDs)
            board.didShowAgain()
            if closesOpenMoment {
                router.keptPath = []
            }
        }
    }

    /// Show All Again: every live kept photo, no Undo (the dialog asked first).
    private func showAllAgain() {
        guard let curator else { return }
        curator.restoreAll()
        board.didShowAgain()
        router.keptPath = []
    }
}

/// A pending Show All Again confirmation.
private struct KeptShowAllRequest: Hashable {
    let moments: Int
}

// MARK: - Row

/// One kept moment: a `MomentCard` with the date and count, Show Again on both swipe edges,
/// and a context menu with Show Again and View.
private struct KeptMomentRow: View {
    /// Passed into context-menu previews, which iOS hosts outside this view's environment.
    @Environment(\.imageLoader) private var previewLoader
    let moment: Moment
    /// Stack: a tap opens the moment. Split: the list's selection does.
    let opensOnTap: Bool
    let namespace: Namespace.ID
    let onOpen: () -> Void
    let onShowAgain: () -> Void
    /// Tracks the card under the list's focus line, for the background.
    let focus: ScrollFocus<MomentID>

    var body: some View {
        MomentCard(moment: moment, showsDate: true)
            .matchedTransitionSource(id: moment.id, in: namespace) { source in
                source.clipShape(Theme.Shapes.card)
            }
            .modifier(KeptRowTap(isEnabled: opensOnTap, action: onOpen))
            .accessibilityHint(Text("Opens the moment.", comment: "VoiceOver hint of a kept moment card."))
            .accessibilityIdentifier("kept.card")
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                showAgainButton
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                showAgainButton
            }
            .contextMenu {
                Button(action: onShowAgain) {
                    Label {
                        Text("Show Again", comment: "Kept: put this moment back in Moments.")
                    } icon: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                }
                Button(action: onOpen) {
                    Label {
                        Text("View", comment: "Kept: open this moment.")
                    } icon: {
                        Image(systemName: "eye")
                    }
                }
            } preview: {
                MomentPreview(moment: moment)
                    .environment(\.imageLoader, previewLoader)
            }
            .scrollFocusItem(moment.id, in: focus)
            .cardRow()
    }

    private var showAgainButton: some View {
        Button(action: onShowAgain) {
            Label {
                Text("Show Again", comment: "Kept card swipe action: put this moment back in Moments.")
            } icon: {
                Image(systemName: "arrow.uturn.backward")
            }
        }
        .tint(Theme.Palette.keep)
    }
}

/// The card's tap in the stack, with the same action for VoiceOver.
private struct KeptRowTap: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onTapGesture(perform: action)
                .accessibilityAction { action() }
        } else {
            content
        }
    }
}

// MARK: - Section headers

private struct KeptSectionTitle: View {
    let title: Text

    init(_ title: Text) {
        self.title = title
    }

    var body: some View {
        title
            .font(.title3.bold())
            .foregroundStyle(.primary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

/// "Photos you picked  12  ⌄": a button that opens and closes the section.
private struct KeptPickedHeader: View {
    let photoCount: Int
    @Binding var isExpanded: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy) {
                isExpanded.toggle()
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Text("Photos you picked", comment: "Kept tab: section of photos kept while the rest of their moment was deleted.")
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                Text(photoCount, format: .number)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: Theme.Spacing.small)
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .textCase(nil)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(
            "Photos you picked, \(photoCount) photos",
            comment: "VoiceOver label of the Photos you picked section header. 1: number of photos."
        ))
        .accessibilityHint(isExpanded
            ? Text("Hides these moments.", comment: "VoiceOver hint of the open Photos you picked header.")
            : Text("Shows these moments.", comment: "VoiceOver hint of the closed Photos you picked header."))
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Layout helpers

/// The list's background in the stack: the strip while the list shows. In a split the sidebar
/// paints nothing, so the detail's photo shows through its glass.
private struct KeptScreenBackground: ViewModifier {
    let paints: Bool
    let strip: ScrollFocus<MomentID>?

    func body(content: Content) -> some View {
        if paints {
            content.modifier(KeptListAmbient(strip: strip))
        } else {
            content
        }
    }
}

/// Keeps the cards at a readable width in a wide stack (the open Duo turned, a 700 pt window).
private struct KeptReadableMargins: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.readableContentMargins()
        } else {
            content
        }
    }
}
