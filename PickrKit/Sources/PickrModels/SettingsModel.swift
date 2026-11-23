import Foundation
import Observation
import PickrCore
import PickrPersistence

/// Settings and lifetime stats. Stored properties are mirrored to UserDefaults in didSet.
///
/// - The settings are read from UserDefaults when the model is created. Reading writes
///   nothing, so `MigrationV1.isUpgrade` still sees an untouched v1 store afterwards.
/// - The stats and `showsWhatsNew` arrive in `AppServices.launch()`, after the migration
///   (§4.5). Until then the stats read zero.
/// - A grouping change regroups the Moments list at once, with no PhotoKit call.
/// - Stats change only through `Curator`, after PhotoKit confirms a deletion.
@Observable public final class SettingsModel {
    /// The version whose What's New sheet this build shows (`app.whatsNewSeen`).
    public nonisolated static let whatsNewVersion = "2.0"

    public var grouping: GroupingSettings {
        didSet {
            guard grouping != oldValue else { return }
            persist()
            onGroupingChange?()
        }
    }

    public var hapticsEnabled: Bool {
        didSet {
            guard hapticsEnabled != oldValue else { return }
            persist()
        }
    }

    /// Favorites and rated photos start as kept and Delete Moment skips them (Q3).
    public var protectFavorites: Bool {
        didSet {
            guard protectFavorites != oldValue else { return }
            persist()
        }
    }

    public private(set) var onboardingCompleted: Bool
    public private(set) var stats: LifetimeStats
    /// What was deleted since the app launched (COPY.md **Just now**): the part of `stats`
    /// that `recordDeletion` added in this app session. `firstUse` is the launch time.
    public private(set) var sessionStats: LifetimeStats
    /// `true` for an upgrader from v1 who hasn't seen What's New for this version yet.
    public private(set) var showsWhatsNew: Bool

    /// Runs after every grouping change; `AppServices` points it at `LibraryModel.regroup()`.
    @ObservationIgnored var onGroupingChange: (() -> Void)?

    @ObservationIgnored private let repository: SettingsRepository
    @ObservationIgnored private let statsRepository: StatsRepository
    @ObservationIgnored private var whatsNewSeen: String?
    /// While `true`, didSet doesn't write: the values are being loaded, not changed.
    @ObservationIgnored private var isLoading = false

    init(repository: SettingsRepository, statsRepository: StatsRepository, now: Date) {
        self.repository = repository
        self.statsRepository = statsRepository
        let stored = repository.load()
        grouping = stored.grouping
        hapticsEnabled = stored.hapticsEnabled
        protectFavorites = stored.protectFavorites
        onboardingCompleted = stored.onboardingCompleted
        whatsNewSeen = stored.whatsNewSeen
        stats = LifetimeStats(photosDeleted: 0, bytesFreed: 0, momentsCleared: 0, firstUse: now)
        sessionStats = LifetimeStats(photosDeleted: 0, bytesFreed: 0, momentsCleared: 0, firstUse: now)
        showsWhatsNew = false
    }

    /// Called once the user has passed the access step of onboarding.
    public func completeOnboarding() {
        guard !onboardingCompleted else { return }
        onboardingCompleted = true
        persist()
    }

    /// Records that What's New was shown, so it never shows again for this version.
    public func dismissWhatsNew() {
        showsWhatsNew = false
        guard whatsNewSeen != Self.whatsNewVersion else { return }
        whatsNewSeen = Self.whatsNewVersion
        persist()
    }

    // MARK: - Internal (AppServices and Curator)

    /// Step 3 and 5 of the launch order (§4.5): reloads the settings the migration may have
    /// completed, loads the stats (which writes the first-use date when absent), and decides
    /// whether What's New shows.
    func applyLaunchState(wasUpgrade: Bool, now: Date) {
        let stored = repository.load()
        isLoading = true
        grouping = stored.grouping
        hapticsEnabled = stored.hapticsEnabled
        protectFavorites = stored.protectFavorites
        isLoading = false
        onboardingCompleted = stored.onboardingCompleted
        whatsNewSeen = stored.whatsNewSeen
        stats = statsRepository.load(now: now)
        showsWhatsNew = wasUpgrade && stored.whatsNewSeen != Self.whatsNewVersion
    }

    /// Records one deletion PhotoKit confirmed. Only `Curator` calls this.
    func recordDeletion(deleted: Int, bytes: Int64, momentCleared: Bool) {
        stats = statsRepository.record(deleted: deleted, bytes: bytes, momentCleared: momentCleared)
        // Same rules as the repository: negative amounts count as 0, totals stop at .max.
        var session = sessionStats
        session.photosDeleted = Self.adding(session.photosDeleted, max(deleted, 0))
        session.bytesFreed = Self.adding(session.bytesFreed, max(bytes, 0))
        if momentCleared { session.momentsCleared = Self.adding(session.momentsCleared, 1) }
        sessionStats = session
    }

    private static func adding<T: FixedWidthInteger>(_ total: T, _ amount: T) -> T {
        let (sum, overflow) = total.addingReportingOverflow(amount)
        return overflow ? .max : sum
    }

    private func persist() {
        guard !isLoading else { return }
        repository.save(StoredSettings(
            grouping: grouping,
            hapticsEnabled: hapticsEnabled,
            protectFavorites: protectFavorites,
            onboardingCompleted: onboardingCompleted,
            whatsNewSeen: whatsNewSeen
        ))
    }
}
