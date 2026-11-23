#if DEBUG
import Foundation
import PickrCore
import PickrModels
import PickrPersistence
import SwiftUI

// Preview support for the Adjust, Pick Dates and help screens: real models (`AppServices`)
// over an in-memory photo library with synthetic records, so the summary, the regroup and the
// chart behave as in the app. Debug builds only; no PhotoKit, no files written.

/// A synthetic photo library for previews: about 20 months of bursts and single photos, with
/// sizes, all relative to now.
nonisolated final class AdjustPreviewLibrary: PhotoLibraryClient {
    nonisolated enum Kind: Sendable {
        /// Ready, with photos.
        case photos
        /// Ready, with no photos.
        case empty
        /// Still reading the library: progress with no total, never finishing.
        case indexing
    }

    let kind: Kind
    let records: [AssetRecord]
    let sizes: SizeTable

    init(_ kind: Kind, now: Date = .now) {
        self.kind = kind
        records = kind == .photos ? Self.makeRecords(now: now) : []
        var sizes = SizeTable()
        for (offset, record) in records.enumerated() {
            sizes[record.id] = 1_500_000 + Int64(offset % 7) * 450_000
        }
        self.sizes = sizes
    }

    func access() async -> LibraryAccess { .full }

    func requestAccess() async -> LibraryAccess { .full }

    func indexEvents() -> AsyncStream<IndexEvent> {
        let kind = kind
        let snapshot = IndexSnapshot(records: records, isComplete: true)
        return AsyncStream { continuation in
            switch kind {
            case .photos, .empty: continuation.yield(.snapshot(snapshot))
            case .indexing: continuation.yield(.progress(done: 0, total: 0))
            }
        }
    }

    func refresh() async {}

    func resolveSizes(_ ids: [PhotoID]) async -> SizeTable {
        var table = SizeTable()
        for id in ids {
            if let size = sizes[id] { table[id] = size }
        }
        return table
    }

    func currentRecords(_ ids: [PhotoID]) async -> [AssetRecord] {
        let wanted = Set(ids)
        return records.filter { wanted.contains($0.id) }
    }

    func existingIDs(among ids: [PhotoID]) async -> Set<PhotoID> {
        Set(ids).intersection(records.map(\.id))
    }

    func delete(_ ids: [PhotoID]) async throws(LibraryError) -> DeletionReceipt {
        throw .cancelled
    }

    /// Bursts of 2–7 photos a few seconds apart, a few singles, more photos in summer months.
    private static func makeRecords(now: Date) -> [AssetRecord] {
        var generator = PreviewRandom(seed: 0x5EED)
        var records: [AssetRecord] = []
        var day = 0
        while day < 600 {
            let date = now.addingTimeInterval(-Double(day) * 86_400 - Double(generator.next(upTo: 36_000)))
            let burst = 1 + generator.next(upTo: 7)
            var time = date
            for _ in 0..<burst {
                records.append(AssetRecord(
                    id: PhotoID("preview-\(records.count)"),
                    created: time,
                    isFavorite: generator.next(upTo: 25) == 0
                ))
                time = time.addingTimeInterval(Double(2 + generator.next(upTo: 40)))
            }
            day += 1 + generator.next(upTo: day % 365 < 120 ? 3 : 6)
        }
        return records.sorted(by: AssetRecord.inCaptureOrder)
    }
}

/// A small deterministic generator, so every preview shows the same library.
private nonisolated struct PreviewRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next(upTo bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(max(bound, 1)))
    }
}

/// Builds preview models for the Grouping screens.
enum AdjustPreview {
    /// Real models over `library`. `configure` runs before launch, so the choices it makes are
    /// what the screens first show.
    static func services(
        library: AdjustPreviewLibrary.Kind = .photos,
        configure: (SettingsModel) -> Void = { _ in }
    ) -> AppServices {
        let services = AppServices(
            client: AdjustPreviewLibrary(library),
            defaults: InMemoryKeyValueStore(),
            keptURL: URL.temporaryDirectory.appending(path: "pickr-adjust-preview-\(UUID().uuidString).json"),
            now: { Date.now }
        )
        configure(services.settings)
        return services
    }

    /// Picked dates: the last three months.
    static var savedDates: ScanRange {
        let calendar = Calendar.autoupdatingCurrent
        let end = calendar.startOfDay(for: .now).addingTimeInterval(86_399)
        let start = calendar.date(byAdding: .month, value: -3, to: calendar.startOfDay(for: .now)) ?? end
        return ScanRange(preset: .custom, custom: CustomRange(start, end))
    }
}

extension View {
    /// Injects the preview models the way `PickrApp` injects the live ones, and launches them.
    func adjustPreviewEnvironment(_ services: AppServices) -> some View {
        environment(services.settings)
            .environment(services.kept)
            .environment(services.library)
            .environment(services.toasts)
            .environment(services.router)
            .environment(\.curator, services.curator)
            .task { await services.launch() }
    }
}
#endif
