#if DEBUG
import PickrCore
import PickrModels
import PickrPersistence
import SwiftUI

// Previews for every Review state, on real models: `AppServices` over an in-memory photo
// library (synthetic records, no PhotoKit), an in-memory settings store and a throwaway
// kept.json. Images are `SwatchImageLoader`'s solid colours. Deletes "succeed" in memory, so
// Delete, Keep All and Skip move on as in the app. (The app target can't link
// PickrTestSupport's FakePhotoLibrary, so this is a small stand-in with the same idea.)

private enum ReviewPreviewScenario {
    /// All, nothing kept: the status text, no main button.
    case undecided
    /// All, two kept: trash badges and "Delete N Photos / Frees up …".
    case partial
    /// All, every photo kept: "Keep All & Next".
    case allKept
    /// One by One on the second photo, one photo kept.
    case single
    /// The split's detail column (iPad, the open iPhone Duo).
    case split
}

private struct ReviewPreviewHost: View {
    let scenario: ReviewPreviewScenario

    @State private var services = ReviewPreviewLibrary.makeServices()
    @Namespace private var namespace

    var body: some View {
        container
            .environment(services.settings)
            .environment(services.kept)
            .environment(services.library)
            .environment(services.toasts)
            .environment(services.router)
            .environment(\.curator, services.curator)
            .environment(\.imageLoader, SwatchImageLoader())
            .task { await prepare() }
    }

    @ViewBuilder private var container: some View {
        switch scenario {
        case .split:
            NavigationSplitView {
                List(services.library.moments.moments) { moment in
                    Text(moment.start.formatted(date: .omitted, time: .standard))
                }
                .navigationTitle("Moments")
            } detail: {
                NavigationStack {
                    ReviewScreen.destination(namespace: namespace)
                }
                .toastHost(isRaised: true)
            }
            .environment(\.columnLayout, .split)
        default:
            NavigationStack {
                ReviewScreen.destination(namespace: namespace)
            }
            .toastHost(isRaised: true)
        }
    }

    private func prepare() async {
        await services.launch()
        for _ in 0..<200 where services.library.moments.moments.isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
        services.router.startReview(at: nil)
        guard let session = services.router.review, let moment = session.current else { return }
        session.clear()
        switch scenario {
        case .undecided:
            break
        case .partial, .split:
            session.toggle(moment.photos[0].id)
            session.toggle(moment.photos[2].id)
        case .allKept:
            session.selectAll()
        case .single:
            session.toggle(moment.photos[1].id)
            session.showSingle(moment.photos[1].id)
        }
    }
}

/// An in-memory `PhotoLibraryClient` for previews: three moments of synthetic photos taken
/// within the last hour (inside the default "Look back: Month"), some of them favorites.
private nonisolated struct ReviewPreviewLibrary: PhotoLibraryClient {
    let records: [AssetRecord]
    let sizes: SizeTable

    init(now: Date) {
        var records: [AssetRecord] = []
        // Moments of 6, 4 and 23 photos, three seconds apart, ten minutes between moments.
        for (moment, count) in [6, 4, 23].enumerated() {
            let start = now.addingTimeInterval(-3_600 + Double(moment) * 600)
            for index in 0..<count {
                records.append(AssetRecord(
                    id: PhotoID("review-preview-\(moment)-\(index)"),
                    created: start.addingTimeInterval(Double(index) * 3),
                    isFavorite: moment == 0 && index == 4
                ))
            }
        }
        self.records = records
        sizes = Dictionary(uniqueKeysWithValues: records.enumerated().map { offset, record in
            (record.id, Int64(1_200_000 + (offset % 5) * 350_000))
        })
    }

    @MainActor
    static func makeServices() -> AppServices {
        let now = Date.now
        return AppServices(
            client: ReviewPreviewLibrary(now: now),
            defaults: InMemoryKeyValueStore(),
            keptURL: URL.temporaryDirectory.appending(path: "pickr-review-preview-\(UUID().uuidString).json"),
            now: { .now }
        )
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
        sizes.filter { ids.contains($0.key) }
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

#Preview("All · nothing kept") {
    ReviewPreviewHost(scenario: .undecided)
}

#Preview("All · some kept") {
    ReviewPreviewHost(scenario: .partial)
}

#Preview("All · all kept") {
    ReviewPreviewHost(scenario: .allKept)
}

#Preview("One by One") {
    ReviewPreviewHost(scenario: .single)
}

#Preview("Split detail", traits: .landscapeLeft) {
    ReviewPreviewHost(scenario: .split)
}

#Preview("All · some kept · dark") {
    ReviewPreviewHost(scenario: .partial)
        .preferredColorScheme(.dark)
}

#Preview("All · accessibility text") {
    ReviewPreviewHost(scenario: .partial)
        .dynamicTypeSize(.accessibility2)
}

#Preview("Filmstrip and Keep") {
    @Previewable @State var index = 1
    @Previewable @State var kept: Set<PhotoID> = [PhotoID("preview-1")]
    @Previewable @Namespace var glass
    let photos = PreviewPhotos.records(count: 8).map(\.id)
    VStack {
        Spacer()
        GlassEffectContainer(spacing: Theme.Spacing.medium) {
            HStack(spacing: Theme.Spacing.medium) {
                Filmstrip(
                    photos: photos,
                    index: $index,
                    badge: { kept.contains($0) ? .kept : (kept.isEmpty ? .none : .willDelete) },
                    glassNamespace: glass
                )
                KeepToggle(isKept: kept.contains(photos[index]), glassNamespace: glass) {
                    let id = photos[index]
                    if kept.remove(id) == nil { kept.insert(id) }
                }
            }
        }
        .padding()
    }
    .background(LinearGradient(colors: [.teal, .orange], startPoint: .top, endPoint: .bottom))
    .environment(\.imageLoader, SwatchImageLoader())
}
#endif
