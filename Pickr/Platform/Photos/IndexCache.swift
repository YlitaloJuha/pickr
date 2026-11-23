import Foundation
import Photos
import PickrCore

/// The disposable on-disk copy of the library index: `Library/Caches/Pickr/index.v1.plist`
/// (blueprint §1.3 promise 4, §4.5).
///
/// It lets Home appear at launch without a spinner and lets the next refresh ask PhotoKit
/// only for what changed since the saved persistent-change token. It holds photo
/// identifiers, capture and modification dates, favorite and rating flags, and sizes.
/// The system may purge it at any time; a missing, unreadable or outdated file simply
/// means a full build.
///
/// The binary plist is columnar, so loading 50,000 records stays well inside the launch
/// budget (§4.9): string arrays for identifiers, and little-endian packed `Data` columns
/// for the dates, flags and sizes.
nonisolated struct IndexCache: Sendable {
    /// The access level an index was built under. A cache built under another level is
    /// never reused: a limited library and the whole library hold different photos.
    enum Scope: String, Sendable {
        case full, limited

        init?(_ access: LibraryAccess) {
            switch access {
            case .full: self = .full
            case .limited: self = .limited
            case .notDetermined, .denied: return nil
            }
        }
    }

    /// A known size and the modification date it was measured at. A newer modification
    /// date invalidates it.
    struct CachedSize: Hashable, Sendable {
        var bytes: Int64
        var modified: Date?
    }

    /// Everything the cache holds.
    struct Contents: Equatable, Sendable {
        var scope: Scope
        /// Ascending by `(created, id)`.
        var records: [AssetRecord]
        var sizes: [PhotoID: CachedSize]
        /// The `PHPersistentChangeToken` the records are current to, archived with secure
        /// coding (`PHPersistentChangeToken.h:14`).
        var token: Data?
    }

    static let formatVersion = 1

    let url: URL

    init(url: URL = IndexCache.defaultURL) {
        self.url = url
    }

    /// `Library/Caches/Pickr/index.v1.plist`. Caches are not backed up.
    static var defaultURL: URL {
        URL.cachesDirectory
            .appending(path: "Pickr", directoryHint: .isDirectory)
            .appending(path: "index.v1.plist", directoryHint: .notDirectory)
    }

    // MARK: Reading and writing

    /// The saved contents, or `nil` when there is no usable cache.
    func load() -> Contents? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Self.decode(data)
    }

    /// Writes atomically, creating the folder when needed.
    func save(_ contents: Contents) throws {
        let data = try Self.encode(contents)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Deletes the file. A missing file is not an error.
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Change tokens

    static func archive(_ token: PHPersistentChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    static func unarchiveToken(from data: Data) -> PHPersistentChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }

    // MARK: Format

    private enum Key {
        static let version = "version"
        static let scope = "scope"
        static let ids = "ids"
        static let created = "created"
        static let modified = "modified"
        static let flags = "flags"
        static let sizeIDs = "sizeIDs"
        static let sizeBytes = "sizeBytes"
        static let sizeModified = "sizeModified"
        static let token = "token"
    }

    /// Bit 0: favorite. Bits 1-3: rating 0...5.
    private static func flags(for record: AssetRecord) -> UInt8 {
        (record.isFavorite ? 1 : 0) | (UInt8(min(max(record.rating, 0), 5)) << 1)
    }

    static func encode(_ contents: Contents) throws -> Data {
        let records = contents.records
        let sizes = contents.sizes.sorted { $0.key < $1.key }
        var plist: [String: Any] = [
            Key.version: formatVersion,
            Key.scope: contents.scope.rawValue,
            Key.ids: records.map(\.id.rawValue),
            Key.created: Packing.pack(records.map { $0.created.timeIntervalSinceReferenceDate }),
            Key.modified: Packing.pack(records.map { $0.modified?.timeIntervalSinceReferenceDate ?? .nan }),
            Key.flags: Data(records.map(flags(for:))),
            Key.sizeIDs: sizes.map(\.key.rawValue),
            Key.sizeBytes: Packing.pack(sizes.map(\.value.bytes)),
            Key.sizeModified: Packing.pack(sizes.map { $0.value.modified?.timeIntervalSinceReferenceDate ?? .nan }),
        ]
        if let token = contents.token { plist[Key.token] = token }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    /// The contents of `data`, or `nil` when it is not a valid version-1 cache.
    static func decode(_ data: Data) -> Contents? {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            plist[Key.version] as? Int == formatVersion,
            let scope = (plist[Key.scope] as? String).flatMap(Scope.init(rawValue:)),
            let ids = plist[Key.ids] as? [String],
            let created = (plist[Key.created] as? Data).flatMap(Packing.unpackDoubles),
            let modified = (plist[Key.modified] as? Data).flatMap(Packing.unpackDoubles),
            let flags = plist[Key.flags] as? Data,
            let sizeIDs = plist[Key.sizeIDs] as? [String],
            let sizeBytes = (plist[Key.sizeBytes] as? Data).flatMap(Packing.unpackInt64s),
            let sizeModified = (plist[Key.sizeModified] as? Data).flatMap(Packing.unpackDoubles),
            created.count == ids.count, modified.count == ids.count, flags.count == ids.count,
            sizeBytes.count == sizeIDs.count, sizeModified.count == sizeIDs.count
        else { return nil }

        var records: [AssetRecord] = []
        records.reserveCapacity(ids.count)
        for (index, flag) in zip(ids.indices, flags) {
            guard created[index].isFinite else { return nil }
            records.append(AssetRecord(
                id: PhotoID(ids[index]),
                created: Date(timeIntervalSinceReferenceDate: created[index]),
                modified: date(modified[index]),
                isFavorite: flag & 1 != 0,
                rating: min(Int(flag >> 1), 5)
            ))
        }
        // The index is saved sorted; repair a file that is not rather than trust it.
        if zip(records, records.dropFirst()).contains(where: { AssetRecord.inCaptureOrder($1, $0) }) {
            records.sort(by: AssetRecord.inCaptureOrder)
        }

        var sizes: [PhotoID: CachedSize] = [:]
        sizes.reserveCapacity(sizeIDs.count)
        for index in sizeIDs.indices where sizeBytes[index] >= 0 {
            sizes[PhotoID(sizeIDs[index])] = CachedSize(bytes: sizeBytes[index], modified: date(sizeModified[index]))
        }

        return Contents(scope: scope, records: records, sizes: sizes, token: plist[Key.token] as? Data)
    }

    private static func date(_ interval: Double) -> Date? {
        interval.isFinite ? Date(timeIntervalSinceReferenceDate: interval) : nil
    }
}

/// Little-endian packing of numeric columns into `Data`.
nonisolated enum Packing {
    static func pack(_ values: [Double]) -> Data {
        values.map { $0.bitPattern.littleEndian }.withUnsafeBytes { Data($0) }
    }

    static func pack(_ values: [Int64]) -> Data {
        values.map(\.littleEndian).withUnsafeBytes { Data($0) }
    }

    static func unpackDoubles(_ data: Data) -> [Double]? {
        unpackWords(data)?.map { Double(bitPattern: $0) }
    }

    static func unpackInt64s(_ data: Data) -> [Int64]? {
        unpackWords(data)?.map { Int64(bitPattern: $0) }
    }

    private static func unpackWords(_ data: Data) -> [UInt64]? {
        let width = MemoryLayout<UInt64>.size
        guard data.count.isMultiple(of: width) else { return nil }
        return data.withUnsafeBytes { raw in
            (0..<(raw.count / width)).map { index in
                UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: index * width, as: UInt64.self))
            }
        }
    }
}
