import Foundation
import os
import PickrCore
import PickrPersistence

/// The composition root: owns every model and wires them together.
///
/// Creating it reads the settings and nothing else: no file is touched and nothing is
/// written, so `MigrationV1.isUpgrade` still sees an untouched v1 store afterwards. The
/// rest happens in `launch()`.
public final class AppServices {
    public let settings: SettingsModel
    public let kept: KeptModel
    public let library: LibraryModel
    public let toasts: ToastCenter
    public let curator: Curator
    public let router: Router

    private let defaults: any KeyValueStore
    private let keptStore: KeptStore
    private let now: @Sendable () -> Date
    private var launchTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "com.juha.Culler", category: "Launch")

    public init(client: any PhotoLibraryClient, defaults: any KeyValueStore, keptURL: URL, now: @escaping @Sendable () -> Date) {
        self.defaults = defaults
        self.now = now
        keptStore = KeptStore(url: keptURL)
        settings = SettingsModel(
            repository: SettingsRepository(store: defaults),
            statsRepository: StatsRepository(store: defaults),
            now: now()
        )
        kept = KeptModel(store: keptStore)
        toasts = ToastCenter()
        library = LibraryModel(client: client, settings: settings, kept: kept, now: now)
        curator = Curator(client: client, library: library, kept: kept, settings: settings, toasts: toasts, now: now)
        router = Router(library: library, curator: curator, settings: settings, toasts: toasts)

        // Every input change regroups; every list change revalidates the open review.
        settings.onGroupingChange = { [weak library] in library?.regroup() }
        kept.onChange = { [weak library] in library?.regroup() }
        library.keptMaintenance = curator
        library.onMomentsChange = { [weak router] in router?.review?.revalidate() }
    }

    /// Migration → load stores → `library.start()` (§4.5). Runs once; later calls wait for
    /// the first one.
    public func launch() async {
        if let launchTask {
            await launchTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLaunch()
        }
        launchTask = task
        await task.value
    }

    private func performLaunch() async {
        // 1. Before anything writes the first-use date.
        let wasUpgrade = MigrationV1.isUpgrade(defaults)

        // 2. The migration, idempotent; it does nothing once the schema version is 2.
        var migrated = true
        do {
            _ = try await MigrationV1.run(store: defaults, kept: keptStore, now: now())
        } catch {
            // kept.json couldn't be saved. The schema version stays unset, so the migration
            // retries at the next launch; meanwhile KeptModel uses the v1 list from memory.
            Self.log.error("Migration failed: \(String(describing: error), privacy: .public)")
            migrated = false
        }

        // 3 and 5. Settings, stats (writes the first-use date), What's New.
        settings.applyLaunchState(wasUpgrade: wasUpgrade, now: now())
        await kept.load(legacyIDs: MigrationV1.legacyKeptIDs(in: defaults), migrated: migrated)

        // 4. The v1 tip state is mapped by the app (`PickrTips`), which owns TipKit.
        // 6.
        await library.start()
    }
}
