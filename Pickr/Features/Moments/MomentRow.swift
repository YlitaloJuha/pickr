import PickrCore
import PickrModels
import SwiftUI
import TipKit

/// One moment in the Moments list (§3.3 S3, COPY.md): the card and everything you can do
/// with it.
///
/// - Tap opens the moment (`onOpen`). In a split the card under review gets an accent outline.
/// - Swipe right: **Keep All** (full swipe allowed). Swipe left: **Delete All** (full swipe
///   allowed), hidden when every photo is a protected favorite. Both are VoiceOver actions
///   too; the context menu and Review's ⋯ menu are the visible alternatives.
/// - Long press or secondary click: a preview of up to nine photos with **Open**,
///   **Keep All** and **Delete All** ("Favorites are kept." when it skips some).
/// - Delete All of 20 or more photos asks first, in a dialog anchored to this row (a popover
///   in a regular-width window); then iOS shows its own delete dialog.
/// - The card is the zoom source of the pushed Review, and the first card carries the swipe tip.
///
/// The row only decides; `MomentsScreen` performs the actions and plays the haptics, so they
/// still play when the row is gone by the time PhotoKit answers.
struct MomentRow: View {
    /// Passed into context-menu previews, which iOS hosts outside this view's environment.
    @Environment(\.imageLoader) private var previewLoader
    let moment: Moment
    let showsSwipeTip: Bool
    let namespace: Namespace.ID
    let onOpen: (Moment) -> Void
    let onKeepAll: (Moment) -> Void
    let onDeleteAll: (Moment) -> Void

    @Environment(LibraryModel.self) private var library
    @Environment(SettingsModel.self) private var settings
    @Environment(Router.self) private var router
    @Environment(\.curator) private var curator
    @Environment(\.columnLayout) private var columnLayout

    @State private var bulkDelete: BulkDeleteRequest? = nil

    init(
        moment: Moment,
        showsSwipeTip: Bool,
        namespace: Namespace.ID,
        onOpen: @escaping (Moment) -> Void,
        onKeepAll: @escaping (Moment) -> Void,
        onDeleteAll: @escaping (Moment) -> Void
    ) {
        self.moment = moment
        self.showsSwipeTip = showsSwipeTip
        self.namespace = namespace
        self.onOpen = onOpen
        self.onKeepAll = onKeepAll
        self.onDeleteAll = onDeleteAll
    }

    var body: some View {
        let savings = Savings.keepOneEstimate(for: moment, sizes: library.sizes)
        let isSelected = columnLayout == .split && router.reviewSelection == moment.id
        let canDelete = curator?.canDeleteWhole(moment) ?? false
        Button {
            onOpen(moment)
        } label: {
            MomentCard(moment: moment, savings: savings)
                .overlay {
                    if isSelected {
                        Theme.Shapes.card
                            .strokeBorder(Theme.Palette.keep, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: moment.id, in: namespace) { source in
            source.clipShape(Theme.Shapes.card)
        }
        .accessibilityHint(Text(
            "Opens the moment so you can pick what to keep.",
            comment: "VoiceOver hint on a moment card."
        ))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("moments.card")
        .popoverTip(swipeTip)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                SwipeMomentTip().invalidate(reason: .actionPerformed)
                onKeepAll(moment)
            } label: {
                keepAllLabel(systemImage: "checkmark.circle.fill")
            }
            .tint(Theme.Palette.keep)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if canDelete {
                // Tinted rather than `role: .destructive`: the list must not animate the row
                // away before the bulk dialog and the iOS dialog have had their say.
                Button {
                    SwipeMomentTip().invalidate(reason: .actionPerformed)
                    requestDeleteAll()
                } label: {
                    deleteAllLabel(systemImage: "trash.fill")
                }
                .tint(Theme.Palette.delete)
            }
        }
        .contextMenu {
            Button {
                onOpen(moment)
            } label: {
                Label {
                    Text("Open", comment: "Moment context menu: opens the moment to pick what to keep.")
                } icon: {
                    Image(systemName: "play")
                }
            }
            Button {
                onKeepAll(moment)
            } label: {
                keepAllLabel(systemImage: "checkmark.circle")
            }
            Button(role: .destructive) {
                requestDeleteAll()
            } label: {
                deleteAllLabel(systemImage: "trash")
                if let footnote = deleteFootnote(canDelete: canDelete) {
                    footnote
                }
            }
            .disabled(!canDelete)
        } preview: {
            MomentPreview(moment: moment)
                .environment(\.imageLoader, previewLoader)
        }
        .confirmationDialog(
            Text(
                "Delete all \(bulkDelete?.count ?? 0) photos in this moment?",
                comment: "Dialog before deleting 20 or more photos at once. 1: number of photos."
            ),
            item: $bulkDelete,
            titleVisibility: .visible
        ) { request in
            Button(role: .destructive) {
                onDeleteAll(request.moment)
            } label: {
                Text("Delete \(request.count) Photos", comment: "Bulk-delete dialog: confirms. 1: number of photos.")
            }
            Button(role: .cancel) {} label: {
                Text("Cancel", comment: "Bulk-delete dialog: keeps the photos.")
            }
        } message: { request in
            if request.keepsFavorites {
                Text(
                    "They go to Recently Deleted, where you can get them back for 30 days. Favorites are kept.",
                    comment: "Bulk-delete dialog message when the moment has protected favorites."
                )
            } else {
                Text(
                    "They go to Recently Deleted, where you can get them back for 30 days.",
                    comment: "Bulk-delete dialog message."
                )
            }
        }
        .tag(moment.id)
        .cardRow()
    }

    private var swipeTip: (any Tip)? {
        showsSwipeTip ? SwipeMomentTip() : nil
    }

    private func keepAllLabel(systemImage: String) -> some View {
        Label {
            Text("Keep All", comment: "Keeps every photo of the moment and moves it to Kept.")
        } icon: {
            Image(systemName: systemImage)
        }
    }

    private func deleteAllLabel(systemImage: String) -> some View {
        Label {
            Text("Delete All", comment: "Moves the moment's photos to Recently Deleted (favorites are kept).")
        } icon: {
            Image(systemName: systemImage)
        }
    }

    /// The second line under Delete All in the context menu.
    private func deleteFootnote(canDelete: Bool) -> Text? {
        if !canDelete {
            return Text("All photos in this moment are favorites.", comment: "Under a disabled Delete All.")
        }
        if settings.protectFavorites, moment.photos.contains(where: \.isProtected) {
            return Text("Favorites are kept.", comment: "Under Delete All when the moment has protected favorites.")
        }
        return nil
    }

    /// Delete All: straight to the iOS dialog, or the bulk dialog first at 20 photos or more.
    private func requestDeleteAll() {
        guard let curator, curator.canDeleteWhole(moment) else { return }
        guard curator.needsBulkConfirmation(wholeMoment: moment) else {
            onDeleteAll(moment)
            return
        }
        bulkDelete = BulkDeleteRequest(
            moment: moment,
            count: curator.deletableIDs(wholeMoment: moment).count,
            keepsFavorites: settings.protectFavorites && moment.photos.contains(where: \.isProtected)
        )
    }
}

/// A pending "Delete all 47 photos in this moment?" dialog.
private struct BulkDeleteRequest {
    let moment: Moment
    let count: Int
    let keepsFavorites: Bool
}
