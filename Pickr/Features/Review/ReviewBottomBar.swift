import PickrCore
import PickrModels
import SwiftUI

/// What the bottom bar shows, read from the session in `ReviewScreen`'s body so the bar
/// follows every selection change (§3.3 S4 bottom bar, COPY.md).
struct ReviewBarState: Equatable {
    enum MainAction: Equatable {
        /// Nothing kept yet: the status text instead of a button.
        case none
        /// **Delete 4 Photos** / Frees up 6.8 MB.
        case delete(count: Int, freed: ByteEstimate)
        /// **Keep All & Next**: every photo is kept.
        case keepAll
    }

    /// What Delete All's footnote says.
    enum DeleteAllNote: Equatable {
        case favoritesKept, allFavorites
    }

    var main: MainAction
    var canMoveOn: Bool
    var canCommit: Bool
    var canDeleteWhole: Bool
    var deleteAllNote: DeleteAllNote?

    init(session: ReviewSession, protectFavorites: Bool) {
        switch session.outcome {
        case .undecided: main = .none
        case .partial: main = .delete(count: session.deleteCount, freed: session.deletionEstimate)
        case .keepAll: main = .keepAll
        }
        canMoveOn = session.canMoveOn
        canCommit = session.canCommit
        canDeleteWhole = session.canDeleteWhole
        if !canDeleteWhole {
            deleteAllNote = .allFavorites
        } else if protectFavorites, !(session.current?.protectedIDs.isEmpty ?? true) {
            deleteAllNote = .favoritesKept
        } else {
            deleteAllNote = nil
        }
    }
}

/// A pending "Delete all 47 photos in this moment?" confirmation (≥ 20 photos, §2.5 rail 3).
struct ReviewBulkDelete: Hashable {
    let momentID: MomentID
    let count: Int
}

/// Review's bottom bar (§3.3 S4, ADAPTIVE S4): the ⋯ menu, the status text or the main
/// action, and Skip. System glass; the main action is the screen's one `.glassProminent`
/// button and has the highest visibility priority, so in a narrow window the menu overflows
/// first. In a split it belongs to the detail column.
struct ReviewBottomBar: ToolbarContent {
    let session: ReviewSession
    let state: ReviewBarState
    let bulkDelete: Binding<ReviewBulkDelete?>
    let onCommit: () -> Void
    let onSkip: () -> Void
    let onKeepAll: () -> Void
    let onDeleteAll: () -> Void
    let onConfirmDeleteAll: (ReviewBulkDelete) -> Void
    /// The top of the bar's buttons in window coordinates, for One by One's filmstrip.
    let onTopChange: (CGFloat) -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            ReviewMoreMenu(
                session: session,
                state: state,
                bulkDelete: bulkDelete,
                onKeepAll: onKeepAll,
                onDeleteAll: onDeleteAll,
                onConfirmDeleteAll: onConfirmDeleteAll
            )
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        if state.main == .none {
            ToolbarItem(placement: .status) {
                Text("Tap the photos to keep", comment: "Review's bottom bar while no photo is kept.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
        }
        ToolbarItem(placement: .bottomBar) {
            Button(action: onSkip) {
                Text("Skip", comment: "Review: leave this moment for later and go to the next one.")
            }
            .disabled(!state.canMoveOn)
            .accessibilityHint(Text("Leaves this moment for later.", comment: "VoiceOver hint of Review's Skip button."))
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { onTopChange($0) }
        }
        if state.main != .none {
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                ReviewMainButton(action: state.main, isEnabled: state.canCommit, perform: onCommit)
            }
            .visibilityPriority(.high)
        }
    }
}

// MARK: - ⋯ menu

private struct ReviewMoreMenu: View {
    let session: ReviewSession
    let state: ReviewBarState
    let bulkDelete: Binding<ReviewBulkDelete?>
    let onKeepAll: () -> Void
    let onDeleteAll: () -> Void
    let onConfirmDeleteAll: (ReviewBulkDelete) -> Void

    var body: some View {
        Menu {
            Section {
                Button(action: onKeepAll) {
                    Label {
                        Text("Keep All", comment: "Review ⋯ menu: keep the whole moment and go to the next one.")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                }
                .disabled(!state.canMoveOn)
                Button(role: .destructive, action: onDeleteAll) {
                    Label {
                        Text("Delete All…", comment: "Review ⋯ menu: delete every photo of the moment (favorites are kept).")
                        switch state.deleteAllNote {
                        case .favoritesKept:
                            Text("Favorites are kept.", comment: "Footnote under Delete All when the moment has favorites.")
                        case .allFavorites:
                            Text("All photos in this moment are favorites.", comment: "Footnote under a disabled Delete All.")
                        case nil:
                            EmptyView()
                        }
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
                .disabled(!state.canMoveOn || !state.canDeleteWhole)
            }
        } label: {
            Label {
                Text("More", comment: "Review: the menu with more actions for this moment.")
            } icon: {
                Image(systemName: "ellipsis")
            }
        }
        // Anchored to the menu, so a regular-width window shows it as a popover from here.
        .confirmationDialog(
            Text(
                "Delete all \(bulkDelete.wrappedValue?.count ?? 0) photos in this moment?",
                comment: "Bulk delete dialog title (20 or more photos). 1: number of photos."
            ),
            item: bulkDelete,
            titleVisibility: .visible
        ) { request in
            Button(role: .destructive) {
                onConfirmDeleteAll(request)
            } label: {
                Text("Delete \(request.count) Photos", comment: "Bulk delete dialog: confirm. 1: number of photos.")
            }
            Button(role: .cancel) {} label: {
                Text("Cancel", comment: "Bulk delete dialog: keep the photos.")
            }
        } message: { _ in
            Text(
                "They go to Recently Deleted, where you can get them back for 30 days.",
                comment: "Bulk delete dialog message (20 or more photos)."
            )
        }
    }
}

// MARK: - Main action

/// **Delete 4 Photos** over **Frees up 6.8 MB** in red, or **Keep All & Next** in the accent
/// colour. Falls back to a shorter label when the bar is narrow ("Delete 4 Photos", then
/// "Delete 4"; "Keep All") and uses the shortest one at accessibility text sizes.
private struct ReviewMainButton: View {
    let action: ReviewBarState.MainAction
    let isEnabled: Bool
    let perform: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: perform) {
            label
                .lineLimit(1)
                .multilineTextAlignment(.center)
        }
        .buttonStyle(.glassProminent)
        .tint(action == .keepAll ? Theme.Palette.keep : Theme.Palette.delete)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: action)
    }

    @ViewBuilder private var label: some View {
        switch action {
        case let .delete(count, freed):
            if dynamicTypeSize.isAccessibilitySize {
                shortDelete(count)
            } else {
                ViewThatFits(in: .horizontal) {
                    if let freesUp = ReviewLabels.freesUp(freed) {
                        VStack(spacing: 0) {
                            longDelete(count)
                            Text(freesUp)
                                .font(.caption2)
                        }
                    }
                    longDelete(count)
                    shortDelete(count)
                }
            }
        case .keepAll:
            if dynamicTypeSize.isAccessibilitySize {
                shortKeep
            } else {
                ViewThatFits(in: .horizontal) {
                    Text("Keep All & Next", comment: "Review's main button when every photo is kept: keep the moment and go on.")
                        .fontWeight(.semibold)
                    shortKeep
                }
            }
        case .none:
            EmptyView()
        }
    }

    private func longDelete(_ count: Int) -> some View {
        Text("Delete \(count) Photos", comment: "Review's main button. 1: number of photos to delete.")
            .fontWeight(.semibold)
            .contentTransition(.numericText(value: Double(count)))
    }

    private func shortDelete(_ count: Int) -> some View {
        Text("Delete \(count)", comment: "Review's main button, short form. 1: number of photos to delete.")
            .fontWeight(.semibold)
            .contentTransition(.numericText(value: Double(count)))
    }

    private var shortKeep: some View {
        Text("Keep All", comment: "Review's main button, short form, when every photo is kept.")
            .fontWeight(.semibold)
    }

    private var accessibilityLabel: Text {
        switch action {
        case let .delete(count, freed):
            Text(ReviewLabels.deleteAccessibilityLabel(count: count, freed: freed))
        case .keepAll:
            Text("Keep all and go to the next moment", comment: "VoiceOver label of Keep All & Next.")
        case .none:
            Text(verbatim: "")
        }
    }
}
