import Foundation
import PickrCore
import Testing
@testable import Pickr

@Suite("Index cache")
struct IndexCacheTests {
    let directory: URL

    init() {
        directory = URL.temporaryDirectory.appending(path: "IndexCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func cache() -> IndexCache {
        IndexCache(url: directory.appending(path: "Pickr/index.v1.plist"))
    }

    private static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: 800_000_000 + seconds)
    }

    static let sample = IndexCache.Contents(
        scope: .full,
        records: [
            AssetRecord(id: PhotoID("A/L0/001"), created: date(0), modified: nil, isFavorite: false, rating: 0),
            AssetRecord(id: PhotoID("B/L0/001"), created: date(0), modified: date(5), isFavorite: true, rating: 0),
            AssetRecord(id: PhotoID("C/L0/001"), created: date(3.25), modified: date(9), isFavorite: false, rating: 5),
            AssetRecord(id: PhotoID("D/L0/001"), created: date(120), modified: nil, isFavorite: true, rating: 3),
        ],
        sizes: [
            PhotoID("A/L0/001"): IndexCache.CachedSize(bytes: 1_234_567, modified: nil),
            PhotoID("C/L0/001"): IndexCache.CachedSize(bytes: 9_876_543_210, modified: date(9)),
        ],
        token: Data([1, 2, 3, 4])
    )

    @Test func roundTripsEveryField() throws {
        let cache = cache()
        defer { try? FileManager.default.removeItem(at: directory) }
        try cache.save(Self.sample)
        #expect(cache.load() == Self.sample)
    }

    @Test func roundTripsAnEmptyLimitedIndexWithoutToken() throws {
        let empty = IndexCache.Contents(scope: .limited, records: [], sizes: [:], token: nil)
        #expect(IndexCache.decode(try IndexCache.encode(empty)) == empty)
    }

    @Test func savesUnderLibraryCaches() {
        let url = IndexCache.defaultURL
        #expect(url.lastPathComponent == "index.v1.plist")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Pickr")
        #expect(url.path(percentEncoded: false).contains("/Library/Caches/"))
    }

    @Test func missingFileLoadsNothing() {
        #expect(cache().load() == nil)
    }

    @Test func removeDeletesTheFile() throws {
        let cache = cache()
        defer { try? FileManager.default.removeItem(at: directory) }
        try cache.save(Self.sample)
        cache.remove()
        #expect(cache.load() == nil)
        cache.remove() // A missing file is fine.
    }

    @Test func rejectsGarbage() {
        #expect(IndexCache.decode(Data()) == nil)
        #expect(IndexCache.decode(Data("not a plist".utf8)) == nil)
    }

    @Test func rejectsOtherVersions() throws {
        var plist = try plistDictionary(Self.sample)
        plist["version"] = 2
        #expect(IndexCache.decode(try data(plist)) == nil)
    }

    @Test func rejectsUnknownScope() throws {
        var plist = try plistDictionary(Self.sample)
        plist["scope"] = "everything"
        #expect(IndexCache.decode(try data(plist)) == nil)
    }

    @Test func rejectsMismatchedColumns() throws {
        var plist = try plistDictionary(Self.sample)
        plist["ids"] = ["only-one"]
        #expect(IndexCache.decode(try data(plist)) == nil)

        plist = try plistDictionary(Self.sample)
        plist["created"] = Data([1, 2, 3])
        #expect(IndexCache.decode(try data(plist)) == nil)
    }

    @Test func repairsAnUnsortedFile() throws {
        var reversed = Self.sample
        reversed.records.reverse()
        let decoded = try #require(IndexCache.decode(try IndexCache.encode(reversed)))
        #expect(decoded.records == Self.sample.records)
    }

    @Test func packsColumnsLittleEndian() {
        let doubles: [Double] = [0, -1.5, 1e12, .nan, .infinity]
        let unpacked = Packing.unpackDoubles(Packing.pack(doubles))
        #expect(unpacked?.count == doubles.count)
        #expect(unpacked?[1] == -1.5)
        #expect(unpacked?[3].isNaN == true)
        #expect(Packing.pack([Double(1)]) == Data([0, 0, 0, 0, 0, 0, 0xF0, 0x3F]))

        let ints: [Int64] = [0, 1, -1, .max, .min]
        #expect(Packing.unpackInt64s(Packing.pack(ints)) == ints)
        #expect(Packing.pack([Int64(1)]) == Data([1, 0, 0, 0, 0, 0, 0, 0]))
        #expect(Packing.unpackInt64s(Data([1, 2, 3])) == nil)
    }

    // MARK: Helpers

    private func plistDictionary(_ contents: IndexCache.Contents) throws -> [String: Any] {
        let data = try IndexCache.encode(contents)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func data(_ plist: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }
}
