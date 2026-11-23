import Foundation
import PickrCore

/// The one-time v1 → v2 migration (§4.5).
///
/// The steps, in order:
/// 1. Read the v1 Kept list, `ignoreList.photoIDs`, as `[String]`. Any other type is ignored.
/// 2. Load kept.json if it exists; a crashed earlier run may have left one.
/// 3. Merge (existing items win; new IDs become `.legacy` items without a date) and save
///    atomically. If the save fails, stop: the schema version stays unset, so the migration
///    runs again at the next launch.
/// 4. Upgraders only: if `stats.bytesFreed` is absent, write `round(stats.mbFreed × 1_048_576)`.
/// 5. Upgraders only: if `settings.timeWindowIsCustom` is absent, write whether the clamped
///    seconds are not a preset.
/// 6. Set `app.schemaVersion = 2`, last.
///
/// A fresh install has no v1 data, so it only gets step 6. The legacy keys
/// `ignoreList.photoIDs` and `stats.mbFreed` are never written or removed in 2.x.
public enum MigrationV1 {
    public struct Report: Equatable, Sendable {
        /// `isUpgrade` as it was when the run started.
        public let wasUpgrade: Bool
        /// v1 Kept IDs this run added to kept.json. 0 when an earlier run already had them.
        public let importedKeptIDs: Int
        /// The `stats.bytesFreed` this run wrote, or `nil` if it wrote none.
        public let bytesFreed: Int64?

        public init(wasUpgrade: Bool, importedKeptIDs: Int, bytesFreed: Int64?) {
            self.wasUpgrade = wasUpgrade
            self.importedKeptIDs = importedKeptIDs
            self.bytesFreed = bytesFreed
        }
    }

    /// The `app.schemaVersion` a completed migration writes.
    static let schemaVersion = 2

    /// Whether this launch upgrades a v1 install: v1 left its marks
    /// (`settings.onboardingCompleted == true`, or a `stats.firstUseDate`) and the
    /// migration hasn't completed yet.
    ///
    /// Must run before StatsRepository.load, which writes the first-use date. After a
    /// completed `run` it is `false`, so What's New and the v1 tip mapping belong to the
    /// first v2 launch and never reach a fresh install on its second launch.
    public static func isUpgrade(_ store: any KeyValueStore) -> Bool {
        guard !isComplete(store) else { return false }
        return store.readBool(PersistedKeys.Settings.onboardingCompleted) == true
            || store.object(forKey: PersistedKeys.Stats.firstUseDate) != nil
    }

    /// The v1 Kept list, read-only: `ignoreList.photoIDs` as `[String]`, in stored order,
    /// without duplicates or empty strings. Any other type, and the misnamed `ignoreList.ids`
    /// from the v1 spec, gives an empty list.
    ///
    /// `KeptModel` falls back to these IDs while the migration hasn't completed.
    public static func legacyKeptIDs(in store: any KeyValueStore) -> [PhotoID] {
        guard let raw = store.object(forKey: PersistedKeys.IgnoreList.photoIDs) as? [String] else { return [] }
        var seen = Set<String>()
        return raw.filter { !$0.isEmpty && seen.insert($0).inserted }.map(PhotoID.init)
    }

    /// Idempotent and crash-safe; sets the schema version last.
    ///
    /// Does nothing once the schema version is 2, so calling it at every launch is safe. A
    /// run interrupted at any point redoes only what is missing: items already in kept.json
    /// win, and the stats and window keys are written only while absent.
    ///
    /// `now` isn't used by this version of the migration: v1 recorded no dates for its Kept
    /// list, so legacy items have no `since`.
    /// - Throws: Whatever `KeptStore` throws while loading or saving, except an unreadable
    ///   kept.json, which `KeptStore` has already preserved and which is merged as empty.
    ///   After a throw nothing past the Kept merge has been written.
    public static func run(store: any KeyValueStore, kept: KeptStore, now: Date) async throws -> Report {
        guard !isComplete(store) else {
            return Report(wasUpgrade: false, importedKeptIDs: 0, bytesFreed: nil)
        }
        let wasUpgrade = isUpgrade(store)

        // Steps 1–3. Not gated on `wasUpgrade`: the list only exists where v1 wrote it, and
        // importing it must not depend on any other v1 key being intact.
        let imported = try await importLegacyKept(from: store, into: kept)

        var bytesFreed: Int64?
        if wasUpgrade {
            // Step 4: convert the v1 MiB total exactly once.
            if store.object(forKey: PersistedKeys.Stats.bytesFreed) == nil {
                let bytes = LegacyStats.bytesFreed(in: store)
                store.set(bytes, forKey: PersistedKeys.Stats.bytesFreed)
                bytesFreed = bytes
            }
            // Step 5: v1 couldn't store a custom 1 min or 3 min, so a preset value is a preset.
            if store.object(forKey: PersistedKeys.Settings.timeWindowIsCustom) == nil {
                let isCustom = SettingsRepository.windowIgnoringFlag(in: store).isCustom
                store.set(isCustom, forKey: PersistedKeys.Settings.timeWindowIsCustom)
            }
        }

        // Step 6, last.
        store.set(schemaVersion, forKey: PersistedKeys.App.schemaVersion)
        return Report(wasUpgrade: wasUpgrade, importedKeptIDs: imported, bytesFreed: bytesFreed)
    }

    /// Whether a migration has completed (`app.schemaVersion >= 2`).
    static func isComplete(_ store: any KeyValueStore) -> Bool {
        (store.readInt(PersistedKeys.App.schemaVersion) ?? 0) >= schemaVersion
    }

    /// Steps 1–3. Returns how many IDs were added. Writes nothing when there is nothing new.
    private static func importLegacyKept(from store: any KeyValueStore, into kept: KeptStore) async throws -> Int {
        let legacy = legacyKeptIDs(in: store)
        guard !legacy.isEmpty else { return 0 }

        var file: KeptFile
        do {
            file = try await kept.load()
        } catch KeptStoreError.unreadable {
            // KeptStore moved the unreadable file aside. The v1 list is still intact, so the
            // merge starts again from it.
            file = KeptFile()
        }

        // Orphans count as known: they are confirmed gone and must not come back as items.
        var known = Set(file.items.map(\.id))
        known.formUnion(file.orphans.map(\.id))
        let added = legacy.filter { !known.contains($0) }
        guard !added.isEmpty else { return 0 }

        file.items.append(contentsOf: added.map { KeptItem(id: $0, kind: .legacy, since: nil) })
        try await kept.save(file)
        return added.count
    }
}
