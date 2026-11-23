import Foundation
import PickrCore

/// Why a photo is in Kept. The raw values are persisted in kept.json and never change.
public enum KeptKind: String, Codable, Sendable {
    /// Kept aside as a whole moment.
    case keptAside
    /// Kept while the rest of its moment was deleted.
    case reviewed
    /// Imported from the v1 Kept list (`ignoreList.photoIDs`).
    case legacy
}

/// One photo in Kept.
public struct KeptItem: Hashable, Codable, Sendable {
    public let id: PhotoID
    public var kind: KeptKind
    /// When the photo was kept. `nil` for legacy items: v1 recorded no dates.
    public var since: Date?
    /// iCloud Photos identifier (WP15).
    public var cloudID: String?

    public init(id: PhotoID, kind: KeptKind, since: Date? = nil, cloudID: String? = nil) {
        self.id = id
        self.kind = kind
        self.since = since
        self.cloudID = cloudID
    }
}

/// The contents of `Application Support/Pickr/kept.json`.
///
/// ```json
/// {"items":[{"id":"…/L0/001","kind":"keptAside","since":"2026-11-21T10:00:00Z"}],"orphans":[],"version":1}
/// ```
/// Dates are ISO 8601 with whole seconds. Changing the format means bumping `version` and
/// still reading every earlier version.
public struct KeptFile: Codable, Sendable {
    public var version = 1
    public var items: [KeptItem]
    /// Items confirmed gone from the library, kept for one release.
    public var orphans: [KeptItem]

    public init(items: [KeptItem] = [], orphans: [KeptItem] = []) {
        self.items = items
        self.orphans = orphans
    }

    private enum CodingKeys: String, CodingKey { case version, items, orphans }

    /// A missing `version` reads as 1 and a missing `orphans` list as empty.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        items = try container.decode([KeptItem].self, forKey: .items)
        orphans = try container.decodeIfPresent([KeptItem].self, forKey: .orphans) ?? []
    }
}

/// Why `KeptStore.load()` couldn't return the file.
public enum KeptStoreError: Error, Hashable, Sendable {
    /// The file was written by a newer version of Pickr. It is left untouched.
    case unsupportedVersion(Int)
    /// The file isn't valid kept.json. It was renamed to `preservedAt` (`nil` if the rename
    /// failed) so a later save can't overwrite it, and the next `load()` starts empty.
    case unreadable(preservedAt: URL?)
}

/// Loads and atomically saves the Kept file.
///
/// Saves are atomic and protected until the first unlock (§4.5). A failed save leaves the
/// previous file as it was.
public actor KeptStore {
    /// The newest `KeptFile.version` this build reads.
    static let supportedVersion = 1

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The saved file. With no file yet, an empty one.
    ///
    /// `items` and `orphans` come back with unique IDs; the first entry for an ID wins.
    /// - Throws: `KeptStoreError` when the file is from a newer version or can't be decoded.
    ///   Any other error, such as a read before the first unlock, is rethrown as is.
    public func load() throws -> KeptFile {
        guard let data = try FileStore.read(url) else { return KeptFile() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let version: Int
        do {
            version = try decoder.decode(VersionHeader.self, from: data).version ?? 1
        } catch {
            throw preserveUnreadableFile()
        }
        guard version <= Self.supportedVersion else {
            throw KeptStoreError.unsupportedVersion(version)
        }

        var file: KeptFile
        do {
            file = try decoder.decode(KeptFile.self, from: data)
        } catch {
            throw preserveUnreadableFile()
        }
        file.items = Self.uniqued(file.items)
        file.orphans = Self.uniqued(file.orphans)
        return file
    }

    /// Replaces the file atomically. If the save throws, the previous file is unchanged.
    public func save(_ f: KeptFile) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys keep the bytes stable for equal contents. Local identifiers contain
        // "/", which needs no escaping.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try FileStore.write(encoder.encode(f), to: url)
    }

    private func preserveUnreadableFile() -> KeptStoreError {
        .unreadable(preservedAt: FileStore.moveAside(url, tag: "unreadable"))
    }

    private static func uniqued(_ items: [KeptItem]) -> [KeptItem] {
        var seen = Set<PhotoID>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// Read first, so a newer format is recognised before its body is decoded.
    private struct VersionHeader: Decodable {
        var version: Int?
    }
}
