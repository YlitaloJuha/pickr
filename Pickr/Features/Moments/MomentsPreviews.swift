#if DEBUG
import PickrCore
import PickrModels
import PickrPersistence
import SwiftUI

// Previews for every Moments state, on real models: `AppServices` over an in-memory photo
// library (synthetic records taken in the last weeks, no PhotoKit), an in-memory settings
// store and a throwaway kept.json. Images are `SwatchImageLoader`'s solid colours. Deletes
// "succeed" in memory, so Keep All and Delete All behave as in the app. (The app target
// can't link PickrTestSupport's FakePhotoLibrary, so this is a small stand-in for it.)

/// The library and settings a Moments preview starts from.
nonisolated enum MomentsPreviewScenario: Hashable, Sendable {
    /// Seven moments over the last weeks, Newest First.
    case moments
    /// The same moments with limited access: the banner row.
    case limited
    /// The same moments, Biggest First (no day sections).
    case biggestFirst
    /// Photos, but none taken close together: "All clean".
    case allClean
    /// Photo access off.
    case denied
    /// Photo access never asked (privacy settings reset).
    case primer
    /// The first read of a large library, before the total is known.
    case readingStarted
    /// The first read of a large library, 4,200 of 12,000.
    case reading
    /// The first read failed.
    case failed

    var access: LibraryAccess {
        switch self {
        case .limited: .limited
        case .denied: .denied
        case .primer: .notDetermined
        case .moments, .biggestFirst, .allClean, .readingStarted, .reading, .failed: .full
        }
    }
}

/// Injects preview models (as `PickrApp` does) around `content` and launches them.
struct MomentsPreviewHost<Content: View>: View {
    let scenario: MomentsPreviewScenario
    let content: Content

    init(_ scenario: MomentsPreviewScenario, @ViewBuilder content: () -> Content) {
        self.scenario = scenario
        self.content = content()
    }

    var body: some View {
        content.momentsPreviewEnvironment(scenario)
    }
}

extension MomentsPreviewHost where Content == MomentsColumns {
    /// The whole Moments tab, stacked.
    init(_ scenario: MomentsPreviewScenario) {
        self.init(scenario) {
            MomentsColumns(layout: .constant(.stack))
        }
    }
}

extension View {
    /// The models, curator and a swatch image loader for `scenario`, launched on appear.
    func momentsPreviewEnvironment(_ scenario: MomentsPreviewScenario) -> some View {
        modifier(MomentsPreviewEnvironment(scenario: scenario))
    }
}

private struct MomentsPreviewEnvironment: ViewModifier {
    let scenario: MomentsPreviewScenario

    @State private var services: AppServices

    init(scenario: MomentsPreviewScenario) {
        self.scenario = scenario
        self.services = MomentsPreviewLibrary.makeServices(for: scenario)
    }

    func body(content: Content) -> some View {
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
private nonisolated struct MomentsPreviewLibrary: PhotoLibraryClient {
    let accessLevel: LibraryAccess
    let events: [IndexEvent]
    let records: [AssetRecord]
    let sizes: SizeTable

    init(scenario: MomentsPreviewScenario, now: Date) {
        accessLevel = scenario.access
        records = scenario == .allClean ? Self.singles(now: now) : Self.moments(now: now)
        sizes = Dictionary(uniqueKeysWithValues: records.enumerated().map { offset, record in
            (record.id, Int64(1_100_000 + (offset % 7) * 420_000))
        })
        switch scenario {
        case .readingStarted:
            events = []
        case .reading:
            events = [.progress(done: 4_200, total: 12_000)]
        case .failed:
            events = [.failed(.unavailable)]
        case .moments, .limited, .biggestFirst, .allClean, .denied, .primer:
            events = [.snapshot(IndexSnapshot(records: records, isComplete: true))]
        }
    }

    @MainActor
    static func makeServices(for scenario: MomentsPreviewScenario) -> AppServices {
        var stored: [String: Any] = [
            PersistedKeys.Stats.photosDeleted: 1_234,
            PersistedKeys.Stats.bytesFreed: Int64(2_500_000_000),
            PersistedKeys.Stats.clustersCleared: 312,
        ]
        if scenario == .biggestFirst {
            stored[PersistedKeys.Settings.momentOrder] = MomentOrder.mostSpace.rawValue
        }
        let now = Date.now
        return AppServices(
            client: MomentsPreviewLibrary(scenario: scenario, now: now),
            defaults: InMemoryKeyValueStore(stored),
            keptURL: URL.temporaryDirectory.appending(path: "pickr-moments-preview-\(UUID().uuidString).json"),
            now: { .now }
        )
    }

    /// Seven moments of photos three seconds apart: today, yesterday (two), this week and
    /// earlier this month; one of 21 photos (the bulk dialog), some favorites.
    private static func moments(now: Date) -> [AssetRecord] {
        let plan: [(hoursAgo: Double, count: Int)] = [
            (2, 5), (26, 4), (28, 6), (75, 3), (121, 21), (290, 7), (480, 2),
        ]
        var records: [AssetRecord] = []
        for (moment, step) in plan.enumerated() {
            let start = now.addingTimeInterval(-step.hoursAgo * 3_600)
            for index in 0..<step.count {
                records.append(AssetRecord(
                    id: PhotoID("moments-preview-\(moment)-\(index)"),
                    created: start.addingTimeInterval(Double(index) * 3),
                    isFavorite: moment == 0 && index == 2
                ))
            }
        }
        return records.sorted(by: AssetRecord.inCaptureOrder)
    }

    /// Photos taken at least ten minutes apart: no moments.
    private static func singles(now: Date) -> [AssetRecord] {
        (0..<5).map { index in
            AssetRecord(
                id: PhotoID("moments-preview-single-\(index)"),
                created: now.addingTimeInterval(-Double(index + 1) * 600)
            )
        }
        .sorted(by: AssetRecord.inCaptureOrder)
    }

    func access() async -> LibraryAccess { accessLevel }

    func requestAccess() async -> LibraryAccess { .full }

    func indexEvents() -> AsyncStream<IndexEvent> {
        let events = events
        return AsyncStream { continuation in
            for event in events { continuation.yield(event) }
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
