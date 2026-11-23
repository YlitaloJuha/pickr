import Foundation

/// Lifetime totals shown in Settings > Your progress.
public struct LifetimeStats: Hashable, Sendable {
    public var photosDeleted: Int
    public var bytesFreed: Int64
    public var momentsCleared: Int
    public var firstUse: Date

    public init(photosDeleted: Int, bytesFreed: Int64, momentsCleared: Int, firstUse: Date) {
        self.photosDeleted = photosDeleted
        self.bytesFreed = bytesFreed
        self.momentsCleared = momentsCleared
        self.firstUse = firstUse
    }
}

/// Reads and updates `LifetimeStats` under the §1.2 keys.
///
/// - `photosDeleted` is `stats.photosDeleted`, and `momentsCleared` is the v1 key
///   `stats.clustersCleared`. Both default to 0.
/// - `bytesFreed` is `stats.bytesFreed`. Until the migration has written it, it reads as the
///   v1 `stats.mbFreed` converted from MiB. Once `bytesFreed` exists, `mbFreed` is never read
///   again, so the old total is converted exactly once. Neither path writes `mbFreed`.
/// - `firstUse` is `stats.firstUseDate`, written once.
public struct StatsRepository {
    private typealias Keys = PersistedKeys.Stats

    private let store: any KeyValueStore

    public init(store: any KeyValueStore) {
        self.store = store
    }

    /// Writes the first-use date when it is absent.
    ///
    /// The first-use date marks a v1 user, so call `MigrationV1.isUpgrade(_:)` before the
    /// first `load` of a launch.
    public func load(now: Date) -> LifetimeStats {
        let firstUse: Date
        if let stored = store.readDate(Keys.firstUseDate) {
            firstUse = stored
        } else {
            store.set(now, forKey: Keys.firstUseDate)
            firstUse = now
        }
        return LifetimeStats(
            photosDeleted: store.readInt(Keys.photosDeleted) ?? 0,
            bytesFreed: store.readInt64(Keys.bytesFreed) ?? LegacyStats.bytesFreed(in: store),
            momentsCleared: store.readInt(Keys.clustersCleared) ?? 0,
            firstUse: firstUse
        )
    }

    /// Records one confirmed deletion and returns the new totals.
    ///
    /// Call it only after PhotoKit confirms the deletion: `deleted` is the receipt's count,
    /// `bytes` the known sizes of those photos, and `momentCleared` is `true` for a deletion
    /// inside a moment (never for keep-aside). Negative values count as 0, and totals stop at
    /// their maximum instead of overflowing. Only the totals that change are written.
    @discardableResult
    public func record(deleted: Int, bytes: Int64, momentCleared: Bool) -> LifetimeStats {
        // `load` has already run at launch, so this normally finds the stored first-use date.
        var stats = load(now: .now)
        if deleted > 0 {
            stats.photosDeleted = Self.adding(stats.photosDeleted, deleted)
            store.set(stats.photosDeleted, forKey: Keys.photosDeleted)
        }
        if bytes > 0 {
            stats.bytesFreed = Self.adding(stats.bytesFreed, bytes)
            store.set(stats.bytesFreed, forKey: Keys.bytesFreed)
        }
        if momentCleared {
            stats.momentsCleared = Self.adding(stats.momentsCleared, 1)
            store.set(stats.momentsCleared, forKey: Keys.clustersCleared)
        }
        return stats
    }

    private static func adding<T: FixedWidthInteger>(_ total: T, _ amount: T) -> T {
        let (sum, overflow) = total.addingReportingOverflow(amount)
        return overflow ? .max : sum
    }
}

/// The v1 lifetime "MB freed", which v1 stored in MiB under `stats.mbFreed`.
enum LegacyStats {
    static let bytesPerMiB: Double = 1_048_576

    /// `round(stats.mbFreed × 1_048_576)`; 0 when the key is absent.
    static func bytesFreed(in store: any KeyValueStore) -> Int64 {
        bytes(fromMiB: store.readDouble(PersistedKeys.Stats.mbFreed) ?? 0)
    }

    /// Rounds to the nearest byte, with halves away from zero. Values that aren't finite or
    /// positive give 0, and values beyond `Int64.max` give `Int64.max`.
    static func bytes(fromMiB mib: Double) -> Int64 {
        guard mib.isFinite, mib > 0 else { return 0 }
        let bytes = (mib * bytesPerMiB).rounded(.toNearestOrAwayFromZero)
        // Double(Int64.max) rounds up to 2^63, the first value that doesn't fit.
        return bytes < Double(Int64.max) ? Int64(bytes) : .max
    }
}
