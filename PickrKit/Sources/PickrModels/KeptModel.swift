import Foundation
import Observation
import os
import PickrCore
import PickrPersistence

/// The Kept list: photos that never resurface in Moments.
///
/// - Read-only for views. Every change goes through `Curator`, which calls the internal
///   mutators here; each change is saved to kept.json in the background, in order.
/// - Items whose photo isn't in the library index (deleted, hidden, or outside a limited
///   selection) stay in the list but are not "live": they appear nowhere and Restore All
///   doesn't count them. Pruning moves confirmed-gone items to `orphans` (§2.5 rail 6).
@Observable public final class KeptModel {
    public private(set) var items: [PhotoID: KeptItem] = [:]
    /// The kept IDs, live or not. Kept in step with `items`.
    public private(set) var ids: Set<PhotoID> = []

    /// Runs after every change to `items`; `AppServices` points it at `LibraryModel.regroup()`.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let store: KeptStore
    @ObservationIgnored private var orphans: [KeptItem] = []
    /// `false` when kept.json exists but couldn't be read in a way that makes overwriting it
    /// unsafe (a newer format, or a read before the first unlock). Changes then stay in memory.
    @ObservationIgnored private(set) var canSave = true
    @ObservationIgnored private var pendingSave: KeptFile?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "com.juha.Culler", category: "Kept")

    init(store: KeptStore) {
        self.store = store
    }

    /// Kept photos grouped as moments (single photos included): "Kept aside" and "Reviewed".
    ///
    /// Only live photos (in `index`) appear. "Kept aside" holds kinds `keptAside` and
    /// `legacy`; "Reviewed" holds `reviewed`. Each section is newest first.
    public func groups(index: [AssetRecord], window: TimeWindow) -> (aside: [Moment], reviewed: [Moment]) {
        guard !items.isEmpty else { return ([], []) }
        var aside: [AssetRecord] = []
        var reviewed: [AssetRecord] = []
        for record in index {
            switch items[record.id]?.kind {
            case .keptAside?, .legacy?: aside.append(record)
            case .reviewed?: reviewed.append(record)
            case nil: break
            }
        }
        return (
            Clusterer.moments(from: aside, window: window, minimumCount: 1),
            Clusterer.moments(from: reviewed, window: window, minimumCount: 1)
        )
    }

    /// The kept IDs whose photo is in `index`: what Restore All restores and counts.
    public func liveIDs(in index: [AssetRecord]) -> Set<PhotoID> {
        guard !items.isEmpty else { return [] }
        return Set(index.lazy.map(\.id).filter { self.items[$0] != nil })
    }

    // MARK: - Loading (AppServices)

    /// Loads kept.json.
    ///
    /// `legacyIDs` is the v1 Kept list, which stays read-only in UserDefaults through 2.x.
    /// It is merged in as `legacy` items (existing items and orphans win) in two cases:
    /// - the migration couldn't save it (`migrated == false`, §4.5 step 2.3): merged in memory
    ///   only, and the migration retries at the next launch;
    /// - kept.json was unreadable: `KeptStore` preserved the damaged file, so the recovered
    ///   list is saved as the new kept.json.
    func load(legacyIDs: [PhotoID], migrated: Bool) async {
        var file = KeptFile()
        var recovered = false
        do {
            file = try await store.load()
        } catch KeptStoreError.unreadable {
            Self.log.error("kept.json was unreadable and was preserved; recovering from the v1 list")
            recovered = true
        } catch {
            // A newer format, or a read before the first unlock: never overwrite that file.
            Self.log.error("Couldn't load kept.json: \(String(describing: error), privacy: .public)")
            canSave = false
        }

        var loaded = Dictionary(file.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if !migrated || recovered {
            let known = Set(loaded.keys).union(file.orphans.map(\.id))
            for id in legacyIDs where !known.contains(id) {
                loaded[id] = KeptItem(id: id, kind: .legacy, since: nil)
            }
        }
        orphans = file.orphans
        apply(loaded, save: recovered && !loaded.isEmpty)
    }

    /// Waits until every change so far is on disk (or has failed to save).
    func flush() async {
        while let task = saveTask {
            await task.value
            if saveTask == task { saveTask = nil }
        }
    }

    // MARK: - Mutations (Curator only)

    /// Adds the photos that aren't kept yet and returns the items it added.
    @discardableResult
    func insert(_ photos: some Sequence<PhotoID>, kind: KeptKind, since: Date) -> [KeptItem] {
        var updated = items
        var added: [KeptItem] = []
        for id in photos where updated[id] == nil {
            let item = KeptItem(id: id, kind: kind, since: since)
            updated[id] = item
            added.append(item)
        }
        if !added.isEmpty { apply(updated) }
        return added
    }

    /// Puts items back exactly as they were (Undo of a restore).
    func reinsert(_ restored: [KeptItem]) {
        var updated = items
        for item in restored where updated[item.id] == nil {
            updated[item.id] = item
        }
        if updated.count != items.count { apply(updated) }
    }

    /// Removes the photos that are kept and returns the items it removed.
    @discardableResult
    func remove(_ photos: some Sequence<PhotoID>) -> [KeptItem] {
        var updated = items
        var removed: [KeptItem] = []
        for id in photos {
            if let item = updated.removeValue(forKey: id) { removed.append(item) }
        }
        if !removed.isEmpty { apply(updated) }
        return removed
    }

    /// Moves items whose photos are confirmed gone from the library to `orphans`, where they
    /// stay for one release (§4.5). Returns the moved items.
    @discardableResult
    func moveToOrphans(_ gone: Set<PhotoID>) -> [KeptItem] {
        var updated = items
        var moved: [KeptItem] = []
        for id in gone {
            if let item = updated.removeValue(forKey: id) { moved.append(item) }
        }
        guard !moved.isEmpty else { return [] }
        let known = Set(orphans.map(\.id))
        orphans += moved.filter { !known.contains($0.id) }.sorted { $0.id < $1.id }
        apply(updated)
        return moved
    }

    // MARK: - Private

    private func apply(_ updated: [PhotoID: KeptItem], save: Bool = true) {
        items = updated
        ids = Set(updated.keys)
        if save { scheduleSave() }
        onChange?()
    }

    /// Saves the latest state through one writer task, so saves land in order and a burst
    /// of changes costs one write per turn of the writer.
    private func scheduleSave() {
        guard canSave else { return }
        pendingSave = KeptFile(items: items.values.sorted { $0.id < $1.id }, orphans: orphans)
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            while let file = self?.takePendingSave(), let store = self?.store {
                do {
                    try await store.save(file)
                } catch {
                    Self.log.error("Couldn't save kept.json: \(String(describing: error), privacy: .public)")
                }
            }
            self?.saveTask = nil
        }
    }

    private func takePendingSave() -> KeptFile? {
        defer { pendingSave = nil }
        return pendingSave
    }
}
