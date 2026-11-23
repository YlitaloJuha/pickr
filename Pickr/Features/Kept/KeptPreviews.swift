#if DEBUG
import PickrCore
import PickrModels
import PickrPersistence
import SwiftUI

// Previews for every Kept state, on real models: `AppServices` over an in-memory photo
// library (synthetic records, no PhotoKit), an in-memory settings store and a throwaway
// kept.json written before launch. Images are `SwatchImageLoader`'s solid colours. Show Again
// and Undo work as in the app. (The app target can't link PickrTestSupport's
// FakePhotoLibrary, so this is a small stand-in with the same idea.)

private enum KeptPreviewScenario {
    /// Moments you kept, Photos you picked collapsed.
    case list
    /// Photos you picked open.
    case pickedOpen
    /// Nothing kept.
    case empty
    /// A kept moment in All.
    case momentAll
    /// A kept moment in One by One, on its second photo.
    case momentSingle
    /// Side by side (iPad, the open iPhone Duo), nothing open.
    case split
    /// Side by side with a moment open.
    case splitOpen
}

private struct KeptPreviewHost: View {
    let scenario: KeptPreviewScenario

    @State private var world = KeptPreviewWorld()

    var body: some View {
        KeptColumns(board: world.board)
            .environment(world.services.settings)
            .environment(world.services.kept)
            .environment(world.services.library)
            .environment(world.services.toasts)
            .environment(world.services.router)
            .environment(\.curator, world.services.curator)
            .environment(\.imageLoader, SwatchImageLoader())
            .task { await world.prepare(scenario) }
    }
}

/// The models, the board and the kept.json behind one preview.
@MainActor
private final class KeptPreviewWorld {
    let keptURL = URL.temporaryDirectory.appending(path: "pickr-kept-preview-\(UUID().uuidString).json")
    let board = KeptBoard()
    let services: AppServices

    init() {
        services = AppServices(
            client: KeptPreviewLibrary(now: .now),
            defaults: InMemoryKeyValueStore(),
            keptURL: keptURL,
            now: { .now }
        )
    }

    func prepare(_ scenario: KeptPreviewScenario) async {
        if scenario != .empty {
            try? await KeptStore(url: keptURL).save(KeptPreviewLibrary.keptFile(now: .now))
        }
        await services.launch()
        for _ in 0..<200 where !(board.isLoaded && services.library.phase == .ready) {
            try? await Task.sleep(for: .milliseconds(25))
        }
        switch scenario {
        case .list, .empty, .split:
            break
        case .pickedOpen:
            board.reviewedExpanded = true
        case .momentAll, .splitOpen:
            services.router.keptSelection = board.aside.first?.id
        case .momentSingle:
            services.router.keptSelection = board.aside.first?.id
            // Let the container see the new moment before choosing the photo.
            try? await Task.sleep(for: .milliseconds(100))
            board.mode = .single
            board.singleIndex = 1
        }
    }
}

/// An in-memory `PhotoLibraryClient` for previews: kept moments, single kept photos and one
/// moment that isn't kept, all in the last two weeks, some of them favorites.
private nonisolated struct KeptPreviewLibrary: PhotoLibraryClient {
    /// (group, photos, days ago, kind); `nil` kind = not kept.
    private static let groups: [(name: String, count: Int, daysAgo: Double, kind: KeptKind?)] = [
        ("forest", 6, 1, .keptAside),
        ("coffee", 3, 3, .keptAside),
        ("sunset", 1, 9, .legacy),
        ("beach", 2, 12, .legacy),
        ("dog", 1, 4, .reviewed),
        ("food", 2, 6, .reviewed),
        ("city", 1, 8, .reviewed),
        ("snow", 5, 2, nil),
    ]

    let records: [AssetRecord]

    init(now: Date) {
        records = Self.groups.flatMap { group in
            let start = now.addingTimeInterval(-group.daysAgo * 86_400)
            return (0..<group.count).map { index in
                AssetRecord(
                    id: Self.id(group.name, index),
                    created: start.addingTimeInterval(Double(index) * 4),
                    isFavorite: index == 1 || group.name == "dog"
                )
            }
        }
        .sorted(by: AssetRecord.inCaptureOrder)
    }

    static func keptFile(now: Date) -> KeptFile {
        let items = groups.flatMap { group -> [KeptItem] in
            guard let kind = group.kind else { return [] }
            return (0..<group.count).map { index in
                KeptItem(id: id(group.name, index), kind: kind, since: kind == .legacy ? nil : now)
            }
        }
        return KeptFile(items: items)
    }

    private static func id(_ group: String, _ index: Int) -> PhotoID {
        PhotoID("kept-preview-\(group)-\(index)")
    }

    func access() async -> LibraryAccess { .full }

    func requestAccess() async -> LibraryAccess { .full }

    func indexEvents() -> AsyncStream<IndexEvent> {
        let snapshot = IndexSnapshot(records: records, isComplete: true)
        return AsyncStream { continuation in
            continuation.yield(.snapshot(snapshot))
            continuation.finish()
        }
    }

    func refresh() async {}

    func resolveSizes(_ ids: [PhotoID]) async -> SizeTable {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, Int64(1_400_000)) })
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

#Preview("Kept") {
    KeptPreviewHost(scenario: .list)
}

#Preview("Kept · Photos you picked open") {
    KeptPreviewHost(scenario: .pickedOpen)
}

#Preview("Kept · nothing kept") {
    KeptPreviewHost(scenario: .empty)
}

#Preview("Kept moment · All") {
    KeptPreviewHost(scenario: .momentAll)
}

#Preview("Kept moment · One by One") {
    KeptPreviewHost(scenario: .momentSingle)
}

#Preview("Side by side", traits: .fixedLayout(width: 1180, height: 820)) {
    KeptPreviewHost(scenario: .split)
        .environment(\.horizontalSizeClass, .regular)
}

#Preview("Side by side · moment open", traits: .fixedLayout(width: 1180, height: 820)) {
    KeptPreviewHost(scenario: .splitOpen)
        .environment(\.horizontalSizeClass, .regular)
}

#Preview("Kept · dark") {
    KeptPreviewHost(scenario: .pickedOpen)
        .preferredColorScheme(.dark)
}

#Preview("Kept · accessibility text") {
    KeptPreviewHost(scenario: .list)
        .dynamicTypeSize(.accessibility2)
}

#Preview("Kept moment · dark") {
    KeptPreviewHost(scenario: .momentAll)
        .preferredColorScheme(.dark)
}
#endif
