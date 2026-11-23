#if DEBUG
import Foundation
import ImageIO
import os
import PickrCore
import Synchronization

/// Demo mode's photo library (`DemoMode`): the 40 synthetic photos of test-photos/, which
/// Debug builds bundle as `test-photos/` (project.yml). Never touches PhotoKit.
///
/// - Full access; nothing is asked.
/// - Capture times come from each file's EXIF `DateTimeOriginal`, read in the device's time
///   zone as Photos would.
/// - Sizes are made up but stable (1.6–4.4 MB a photo, like a phone camera's), so the
///   demos show realistic "to free up" figures; the files themselves are about 117 KB.
/// - Deletes remove photos from memory only, with no dialog, and post a fresh snapshot as
///   PhotoKit's change notification would. Every launch starts with all 40 again.
nonisolated final class DemoPhotoLibrary: PhotoLibraryClient {
    /// The folder test-photos/ is copied to inside the app bundle.
    static let bundleFolder = "test-photos"

    private struct State {
        var records: [PhotoID: AssetRecord]
        var subscribers: [UUID: AsyncStream<IndexEvent>.Continuation] = [:]
    }

    private let state: Mutex<State>
    private let sizes: SizeTable

    private static let log = Logger(subsystem: "com.juha.Culler", category: "Demo")

    init(bundle: Bundle = .main) {
        let records = Self.loadRecords(from: bundle)
        if records.isEmpty {
            Self.log.error("Demo mode found no photos in the app bundle's \(Self.bundleFolder, privacy: .public) folder")
        }
        sizes = Dictionary(uniqueKeysWithValues: records.map { ($0.id, Self.demoSize(of: $0.id)) })
        state = Mutex(State(records: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })))
    }

    deinit {
        let subscribers = state.withLock { Array($0.subscribers.values) }
        for subscriber in subscribers { subscriber.finish() }
    }

    /// The bundled file of a demo photo; its ID is the file name without `.jpg`.
    static func url(for id: PhotoID, in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: id.rawValue, withExtension: "jpg", subdirectory: bundleFolder)
    }

    // MARK: PhotoLibraryClient

    func access() async -> LibraryAccess { .full }

    func requestAccess() async -> LibraryAccess { .full }

    func indexEvents() -> AsyncStream<IndexEvent> {
        let (stream, continuation) = AsyncStream<IndexEvent>.makeStream()
        let key = UUID()
        let snapshot = state.withLock { state in
            state.subscribers[key] = continuation
            return Self.snapshot(of: state.records)
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: key) }
        }
        continuation.yield(.snapshot(snapshot))
        return stream
    }

    func refresh() async {
        emitSnapshot()
    }

    func resolveSizes(_ ids: [PhotoID]) async -> SizeTable {
        ids.reduce(into: SizeTable()) { table, id in
            table[id] = sizes[id]
        }
    }

    func currentRecords(_ ids: [PhotoID]) async -> [AssetRecord] {
        state.withLock { state in ids.compactMap { state.records[$0] } }
    }

    func existingIDs(among ids: [PhotoID]) async -> Set<PhotoID> {
        state.withLock { state in Set(ids.filter { state.records[$0] != nil }) }
    }

    func delete(_ ids: [PhotoID]) async throws(LibraryError) -> DeletionReceipt {
        let receipt: DeletionReceipt? = state.withLock { state in
            var seen = Set<PhotoID>()
            let requested = ids.filter { seen.insert($0).inserted }
            let found = requested.filter { state.records[$0] != nil }
            guard !found.isEmpty else { return nil }
            for id in found { state.records[id] = nil }
            let foundSet = Set(found)
            return DeletionReceipt(deleted: found, missing: requested.filter { !foundSet.contains($0) })
        }
        guard let receipt else { throw .nothingToDelete }
        emitSnapshot()
        return receipt
    }

    // MARK: Private

    private func emitSnapshot() {
        let (snapshot, subscribers) = state.withLock { state in
            (Self.snapshot(of: state.records), Array(state.subscribers.values))
        }
        for subscriber in subscribers { subscriber.yield(.snapshot(snapshot)) }
    }

    private static func snapshot(of records: [PhotoID: AssetRecord]) -> IndexSnapshot {
        IndexSnapshot(records: records.values.sorted(by: AssetRecord.inCaptureOrder), isComplete: true)
    }

    /// Every bundled JPEG with a capture time, in capture order.
    static func loadRecords(from bundle: Bundle) -> [AssetRecord] {
        let urls = bundle.urls(forResourcesWithExtension: "jpg", subdirectory: bundleFolder) ?? []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return urls.compactMap { url -> AssetRecord? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
                  let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
                  let created = formatter.date(from: taken)
            else {
                log.error("Demo photo without a capture time: \(url.lastPathComponent, privacy: .public)")
                return nil
            }
            return AssetRecord(id: PhotoID(url.deletingPathExtension().lastPathComponent), created: created)
        }
        .sorted(by: AssetRecord.inCaptureOrder)
    }

    /// 1.6–4.4 MB, the same for an ID on every launch (FNV-1a, not Swift's seeded hash).
    static func demoSize(of id: PhotoID) -> Int64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in id.rawValue.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return 1_600_000 + Int64(hash % 2_800_001)
    }
}
#endif
