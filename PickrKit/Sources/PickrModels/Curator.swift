import Foundation
import os
import PickrCore
import PickrPersistence

/// The result of committing a review or a whole-moment action.
public nonisolated enum CommitResult: Equatable, Sendable {
    case committed(deleted: Int, freed: ByteEstimate)
    case keptAside
    case cancelled
    case failed(LibraryError)
}

/// The ONLY mutation path for deletes, Kept and stats.
///
/// The safety rails of §2.5 live here (the rest are in the PhotoKit `Deleter`):
/// - Protected photos (favorites, rated) are never part of Delete Moment while "Protect
///   favorites" is on; they survive as `reviewed` Kept items. A photo that became a
///   favorite since indexing is caught by re-reading the records just before the delete.
/// - One PhotoKit request per commit. A cancel is silent and changes nothing.
/// - A real failure shows an error toast with Try Again, on every path, and leaves stats
///   and Kept untouched.
/// - Stats count only what PhotoKit confirmed (`DeletionReceipt.deleted`).
/// - After a delete the keepers go to Kept as `reviewed`, so they never come back as
///   leftovers, and the moment leaves the list at once.
/// - Kept pruning runs only with full access and only for photos confirmed gone.
public final class Curator {
    /// Whole-moment deletes of this many photos or more ask for confirmation first.
    public nonisolated static let bulkConfirmationThreshold = 20

    private let client: any PhotoLibraryClient
    private let library: LibraryModel
    private let kept: KeptModel
    private let settings: SettingsModel
    private let toasts: ToastCenter
    private let now: @Sendable () -> Date

    private static let log = Logger(subsystem: "com.juha.Culler", category: "Curator")

    init(
        client: any PhotoLibraryClient,
        library: LibraryModel,
        kept: KeptModel,
        settings: SettingsModel,
        toasts: ToastCenter,
        now: @escaping @Sendable () -> Date
    ) {
        self.client = client
        self.library = library
        self.kept = kept
        self.settings = settings
        self.toasts = toasts
        self.now = now
    }

    // MARK: - Whole-moment rules

    /// The photos Delete Moment would delete; protection-aware.
    public func deletableIDs(wholeMoment m: Moment) -> [PhotoID] {
        guard settings.protectFavorites else { return m.photoIDs }
        return m.photos.filter { !$0.isProtected }.map(\.id)
    }

    /// `false` when every photo is protected: Delete Moment is disabled, with the footnote
    /// "All photos in this moment are favorites."
    public func canDeleteWhole(_ m: Moment) -> Bool {
        !deletableIDs(wholeMoment: m).isEmpty
    }

    /// `true` when Delete Moment must show the bulk `confirmationDialog` before the PhotoKit
    /// dialog: `bulkConfirmationThreshold` or more deletable photos.
    public func needsBulkConfirmation(wholeMoment m: Moment) -> Bool {
        deletableIDs(wholeMoment: m).count >= Self.bulkConfirmationThreshold
    }

    // MARK: - Commits

    /// Partial delete or keep all.
    ///
    /// - Undecided (nothing kept): does nothing and returns `.cancelled`.
    /// - All kept: keeps the moment aside, like `keepAside(_:)`.
    /// - Otherwise deletes the unkept photos in one PhotoKit request. Protected photos the
    ///   user un-kept are deleted: that is an explicit choice.
    public func commit(_ m: Moment, selection: Selection) async -> CommitResult {
        await commit(m, selection: selection, retry: nil)
    }

    /// Deletes every deletable photo (`deletableIDs(wholeMoment:)`) in one PhotoKit request.
    /// Ask for confirmation first when `needsBulkConfirmation(wholeMoment:)` is `true`.
    public func deleteWhole(_ m: Moment) async -> CommitResult {
        await deleteWhole(m, retry: nil)
    }

    /// `retry` is what the error toast's Try Again runs if the delete fails; by default it
    /// commits the same moment and selection again. `ReviewSession` passes its own, so a
    /// retry also moves the review on.
    func commit(_ m: Moment, selection: Selection, retry: ToastCenter.Action?) async -> CommitResult {
        switch selection.outcome(in: m) {
        case .undecided:
            return .cancelled
        case .keepAll:
            keepAside(m)
            return .keptAside
        case let .partial(keep, delete):
            let retry = retry ?? { [weak self] in _ = await self?.commit(m, selection: selection) }
            return await performDelete(delete, survivors: keep, of: m, retry: retry)
        }
    }

    /// `retry` works as in `commit(_:selection:retry:)`.
    func deleteWhole(_ m: Moment, retry: ToastCenter.Action?) async -> CommitResult {
        var targets = deletableIDs(wholeMoment: m)
        guard !targets.isEmpty else { return .cancelled }
        if settings.protectFavorites {
            // Rail 2: a photo that became a favorite or got a rating since indexing is spared.
            let current = await client.currentRecords(targets)
            let nowProtected = Set(current.lazy.filter(\.isProtected).map(\.id))
            targets.removeAll { nowProtected.contains($0) }
            guard !targets.isEmpty else { return .cancelled }
        }
        let doomed = Set(targets)
        let survivors = m.photoIDs.filter { !doomed.contains($0) }
        let retry = retry ?? { [weak self] in _ = await self?.deleteWhole(m) }
        return await performDelete(targets, survivors: survivors, of: m, retry: retry)
    }

    /// Sends the whole moment to Kept. Undo brings it back.
    public func keepAside(_ m: Moment) {
        let added = kept.insert(m.photoIDs, kind: .keptAside, since: now())
        library.dismissMoment(m.id)
        guard !added.isEmpty else { return }
        let addedIDs = added.map(\.id)
        toasts.show(ToastMessages.keptAside) { [weak self] in
            self?.kept.remove(addedIDs)
        }
    }

    /// Takes photos out of Kept so they can appear in moments again. Undo puts them back.
    public func restore(_ ids: [PhotoID]) {
        let removed = kept.remove(ids)
        guard !removed.isEmpty else { return }
        toasts.show(ToastMessages.shownAgain) { [weak self] in
            self?.kept.reinsert(removed)
        }
    }

    /// Restores every live Kept photo, the ones Restore All counted. Kept items whose photo
    /// isn't in the index (hidden, deleted, outside a limited selection) stay. No undo; the
    /// view confirms first.
    public func restoreAll() {
        let live = kept.liveIDs(in: library.index)
        let removed = kept.remove(live)
        guard !removed.isEmpty else { return }
        toasts.show(ToastMessages.allShownAgain)
    }

    // MARK: - Deletion

    private func performDelete(
        _ targets: [PhotoID],
        survivors: [PhotoID],
        of m: Moment,
        retry: @escaping ToastCenter.Action
    ) async -> CommitResult {
        let receipt: DeletionReceipt
        do {
            receipt = try await client.delete(targets)
        } catch .cancelled {
            return .cancelled
        } catch .nothingToDelete {
            // Everything was already deleted or hidden elsewhere: the photos are gone, so
            // finish the moment without counting anything.
            settleMoment(m, survivors: survivors, gone: targets)
            toasts.show(ToastMessages.nothingToDelete)
            return .failed(.nothingToDelete)
        } catch {
            Self.log.error("Delete failed: \(String(describing: error), privacy: .public)")
            toasts.showError(ToastMessages.deleteFailed(error), retry: retry)
            if error == .notAuthorized {
                await library.refresh()
            }
            return .failed(error)
        }

        guard !receipt.deleted.isEmpty else {
            settleMoment(m, survivors: survivors, gone: receipt.missing)
            toasts.show(ToastMessages.nothingToDelete)
            return .failed(.nothingToDelete)
        }
        let freed = Savings.total(of: receipt.deleted, sizes: library.sizes)
        settings.recordDeletion(deleted: receipt.deleted.count, bytes: freed.bytes, momentCleared: true)
        settleMoment(m, survivors: survivors, gone: receipt.deleted + receipt.missing)
        toasts.show(ToastMessages.deleted(count: receipt.deleted.count, freed: freed))
        return .committed(deleted: receipt.deleted.count, freed: freed)
    }

    /// The moment is done: survivors go to Kept as `reviewed`, gone photos leave the index,
    /// and the card leaves the list now rather than at the next library change.
    private func settleMoment(_ m: Moment, survivors: [PhotoID], gone: [PhotoID]) {
        if !survivors.isEmpty {
            kept.insert(survivors, kind: .reviewed, since: now())
        }
        library.removeDeleted(gone)
        library.dismissMoment(m.id)
    }
}

// MARK: - Kept pruning

extension Curator: KeptMaintenance {
    /// Kept IDs missing from a complete index are checked with `existingIDs(among:)`, which
    /// includes hidden photos, so a hidden photo is never pruned. Full access only: in a
    /// limited library "missing" just means "not selected".
    func pruneMissing() async {
        guard library.access == .full else { return }
        let candidates = missingFromIndex(kept.ids)
        guard !candidates.isEmpty else { return }
        let existing = await client.existingIDs(among: candidates.sorted())
        // Access, the index or Kept may have changed while PhotoKit answered.
        guard library.access == .full else { return }
        let gone = missingFromIndex(candidates.intersection(kept.ids)).subtracting(existing)
        kept.moveToOrphans(gone)
    }

    /// The IDs in `ids` that aren't in the library index. One pass over the index with no
    /// large allocation; Kept is usually far smaller than the library.
    private func missingFromIndex(_ ids: Set<PhotoID>) -> Set<PhotoID> {
        var missing = ids
        for record in library.index {
            guard !missing.isEmpty else { break }
            missing.remove(record.id)
        }
        return missing
    }

    /// The library's persistent history reported these photos deleted.
    func pruneConfirmedDeleted(_ ids: Set<PhotoID>) {
        guard library.access == .full else { return }
        kept.moveToOrphans(ids.intersection(kept.ids))
    }
}
