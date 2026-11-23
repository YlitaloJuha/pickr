#if DEBUG
import PickrCore
import PickrModels
import PickrPersistence
import SwiftUI

// Previews for the root, onboarding, What's New and Settings, on real models: `AppServices`
// over an in-memory photo library (seven synthetic moments from the last weeks, no PhotoKit),
// an in-memory settings store seeded like a fresh install, a returning 2.0 user or a 1.0
// upgrader, and a throwaway kept.json. Images are `SwatchImageLoader`'s solid colours. (The app
// target can't link PickrTestSupport's FakePhotoLibrary, so this is a small stand-in for it.)

/// Who is opening the app in a root preview.
nonisolated enum RootPreviewScenario: Hashable, Sendable {
    /// A fresh install: onboarding, photo access not asked yet. Allow Photo Access grants it.
    case newUser
    /// A returning 2.0 user with full access: the tabs and seven moments.
    case returning
    /// A 1.0 user opening 2.0 for the first time: the tabs and What's New.
    case upgrader
    /// A returning user who turned photo access off.
    case denied
}

/// Injects preview models (as `PickrApp` does) around `content` and launches them.
struct RootPreviewHost<Content: View>: View {
    private let content: Content
    @State private var services: AppServices

    init(_ scenario: RootPreviewScenario, @ViewBuilder content: () -> Content) {
        self.content = content()
        services = RootPreviewLibrary.makeServices(for: scenario)
    }

    var body: some View {
        content
            .environment(services.settings)
            .environment(services.kept)
            .environment(services.library)
            .environment(services.toasts)
            .environment(services.router)
            .environment(\.curator, services.curator)
            .environment(\.imageLoader, SwatchImageLoader())
            .task { await services.launch() }
    }
}

/// An in-memory `PhotoLibraryClient` for previews.
private nonisolated struct RootPreviewLibrary: PhotoLibraryClient {
    let accessLevel: LibraryAccess
    let records: [AssetRecord]
    let sizes: SizeTable

    init(access: LibraryAccess, now: Date) {
        accessLevel = access
        records = Self.moments(now: now)
        sizes = Dictionary(uniqueKeysWithValues: records.enumerated().map { offset, record in
            (record.id, Int64(1_200_000 + (offset % 7) * 410_000))
        })
    }

    @MainActor
    static func makeServices(for scenario: RootPreviewScenario) -> AppServices {
        let now = Date.now
        let firstUse = Calendar.autoupdatingCurrent.date(byAdding: .month, value: -7, to: now) ?? now
        let stored: [String: Any]
        let access: LibraryAccess
        switch scenario {
        case .newUser:
            stored = [:]
            access = .notDetermined
        case .returning, .denied:
            stored = [
                PersistedKeys.Settings.onboardingCompleted: true,
                PersistedKeys.App.schemaVersion: 2,
                PersistedKeys.App.whatsNewSeen: SettingsModel.whatsNewVersion,
                PersistedKeys.Stats.photosDeleted: 1_234,
                PersistedKeys.Stats.bytesFreed: Int64(2_480_000_000),
                PersistedKeys.Stats.clustersCleared: 312,
                PersistedKeys.Stats.firstUseDate: firstUse,
            ]
            access = scenario == .denied ? .denied : .full
        case .upgrader:
            // As 1.0 left it: onboarding done, stats in MiB, no schema version yet.
            stored = [
                PersistedKeys.Settings.onboardingCompleted: true,
                PersistedKeys.Stats.photosDeleted: 412,
                PersistedKeys.Stats.mbFreed: 1_536.5,
                PersistedKeys.Stats.clustersCleared: 37,
                PersistedKeys.Stats.firstUseDate: firstUse,
            ]
            access = .full
        }
        return AppServices(
            client: RootPreviewLibrary(access: access, now: now),
            defaults: InMemoryKeyValueStore(stored),
            keptURL: URL.temporaryDirectory.appending(path: "pickr-root-preview-\(UUID().uuidString).json"),
            now: { .now }
        )
    }

    /// Seven moments of photos three seconds apart over the last three weeks; one has a
    /// favorite.
    private static func moments(now: Date) -> [AssetRecord] {
        let plan: [(hoursAgo: Double, count: Int)] = [
            (3, 5), (27, 4), (30, 6), (76, 3), (122, 8), (290, 7), (480, 2),
        ]
        var records: [AssetRecord] = []
        for (moment, step) in plan.enumerated() {
            let start = now.addingTimeInterval(-step.hoursAgo * 3_600)
            for index in 0..<step.count {
                records.append(AssetRecord(
                    id: PhotoID("root-preview-\(moment)-\(index)"),
                    created: start.addingTimeInterval(Double(index) * 3),
                    isFavorite: moment == 0 && index == 1
                ))
            }
        }
        return records.sorted(by: AssetRecord.inCaptureOrder)
    }

    func access() async -> LibraryAccess { accessLevel }

    func requestAccess() async -> LibraryAccess {
        accessLevel == .notDetermined ? .full : accessLevel
    }

    func indexEvents() -> AsyncStream<IndexEvent> {
        let snapshot = IndexSnapshot(records: records, isComplete: true)
        return AsyncStream { continuation in
            continuation.yield(.snapshot(snapshot))
            continuation.finish()
        }
    }

    func refresh() async {}

    func resolveSizes(_ ids: [PhotoID]) async -> SizeTable {
        let wanted = Set(ids)
        return sizes.filter { wanted.contains($0.key) }
    }

    func currentRecords(_ ids: [PhotoID]) async -> [AssetRecord] {
        let wanted = Set(ids)
        return records.filter { wanted.contains($0.id) }
    }

    func existingIDs(among ids: [PhotoID]) async -> Set<PhotoID> {
        Set(ids).intersection(records.map(\.id))
    }

    func delete(_ ids: [PhotoID]) async throws(LibraryError) -> DeletionReceipt {
        DeletionReceipt(deleted: ids, missing: [])
    }
}
#endif
