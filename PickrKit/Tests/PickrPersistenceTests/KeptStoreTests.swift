import Foundation
import PickrCore
import Testing
@testable import PickrPersistence

@Suite("Kept store")
struct KeptStoreTests {
    static let sample = KeptFile(
        items: [
            KeptItem(id: PhotoID("A1B2C3D4-0000-4000-8000-000000000001/L0/001"), kind: .keptAside, since: date(1_795_255_200)),
            KeptItem(
                id: PhotoID("A1B2C3D4-0000-4000-8000-000000000002/L0/001"),
                kind: .reviewed,
                since: date(1_795_255_260),
                cloudID: "cloud-2"
            ),
            KeptItem(id: PhotoID("A1B2C3D4-0000-4000-8000-000000000003/L0/001"), kind: .legacy),
        ],
        orphans: [KeptItem(id: PhotoID("A1B2C3D4-0000-4000-8000-000000000004/L0/001"), kind: .legacy)]
    )

    @Test func aMissingFileLoadsEmptyAndCreatesNothing() async throws {
        let folder = try TemporaryDirectory()
        let file = try await KeptStore(url: folder.keptURL).load()

        #expect(file.version == 1)
        #expect(file.items.isEmpty)
        #expect(file.orphans.isEmpty)
        #expect(try folder.contents(of: folder.url).isEmpty)
    }

    @Test func atomicWriteRoundTrip() async throws {
        let folder = try TemporaryDirectory()
        try await KeptStore(url: folder.keptURL).save(Self.sample)
        let loaded = try await KeptStore(url: folder.keptURL).load()

        #expect(loaded.version == 1)
        #expect(loaded.items == Self.sample.items)
        #expect(loaded.orphans == Self.sample.orphans)
        #expect(try folder.contents(of: folder.keptURL.deletingLastPathComponent()) == ["kept.json"],
                "No temporary file is left behind")
    }

    @Test func theFileIsVersionedJSONWithISODates() async throws {
        let folder = try TemporaryDirectory()
        try await KeptStore(url: folder.keptURL).save(Self.sample)
        let data = try Data(contentsOf: folder.keptURL)
        let text = try #require(String(data: data, encoding: .utf8))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try #require(json["items"] as? [[String: Any]])

        #expect(json["version"] as? Int == 1)
        #expect((json["orphans"] as? [Any])?.count == 1)
        #expect(items.map { $0["kind"] as? String } == ["keptAside", "reviewed", "legacy"])
        #expect(items[0]["id"] as? String == "A1B2C3D4-0000-4000-8000-000000000001/L0/001")
        #expect(items[0]["since"] as? String == "2026-11-21T10:00:00Z")
        #expect(items[0]["cloudID"] == nil, "Absent optionals are omitted")
        #expect(items[1]["cloudID"] as? String == "cloud-2")
        #expect(items[2]["since"] == nil)
        #expect(text.contains("/L0/001"), "Slashes are not escaped")
    }

    @Test func savingTheSameContentsGivesTheSameBytes() async throws {
        let folder = try TemporaryDirectory()
        let store = KeptStore(url: folder.keptURL)
        try await store.save(Self.sample)
        let first = try Data(contentsOf: folder.keptURL)
        try await store.save(try await store.load())

        #expect(try Data(contentsOf: folder.keptURL) == first)
    }

    @Test func saveCreatesTheFolder() async throws {
        let folder = try TemporaryDirectory()
        let url = folder.url.appending(path: "Application Support/Pickr/kept.json", directoryHint: .notDirectory)
        try await KeptStore(url: url).save(Self.sample)

        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func aFailedSaveLeavesThePreviousFile() async throws {
        let folder = try TemporaryDirectory()
        let store = KeptStore(url: folder.keptURL)
        try await store.save(Self.sample)
        let before = try Data(contentsOf: folder.keptURL)

        // A read-only folder: the temporary file of the atomic write can't be created.
        let parent = folder.keptURL.deletingLastPathComponent().path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent) }

        await #expect(throws: (any Error).self) {
            try await store.save(KeptFile(items: [KeptItem(id: PhotoID("other"), kind: .keptAside)]))
        }
        #expect(try Data(contentsOf: folder.keptURL) == before)
        #expect(try await store.load().items == Self.sample.items)
    }

    @Test func saveThrowsWhenTheFolderCantExist() async throws {
        let folder = try TemporaryDirectory()
        let blocker = folder.url.appending(path: "Pickr", directoryHint: .notDirectory)
        try Data("not a folder".utf8).write(to: blocker)

        await #expect(throws: (any Error).self) {
            try await KeptStore(url: folder.keptURL).save(Self.sample)
        }
    }

    @Test func missingVersionAndOrphansAreTolerated() async throws {
        let folder = try TemporaryDirectory()
        try write(#"{"items":[{"id":"a/L0/001","kind":"legacy"}]}"#, to: folder.keptURL)
        let file = try await KeptStore(url: folder.keptURL).load()

        #expect(file.version == 1)
        #expect(file.items == [KeptItem(id: PhotoID("a/L0/001"), kind: .legacy)])
        #expect(file.orphans.isEmpty)
    }

    @Test func duplicateIDsCollapseToTheFirst() async throws {
        let folder = try TemporaryDirectory()
        try write(
            #"""
            {"version":1,
             "items":[{"id":"a","kind":"keptAside"},{"id":"b","kind":"legacy"},{"id":"a","kind":"reviewed"}],
             "orphans":[{"id":"c","kind":"legacy"},{"id":"c","kind":"reviewed"}]}
            """#,
            to: folder.keptURL
        )
        let file = try await KeptStore(url: folder.keptURL).load()

        #expect(file.items == [KeptItem(id: PhotoID("a"), kind: .keptAside), KeptItem(id: PhotoID("b"), kind: .legacy)])
        #expect(file.orphans == [KeptItem(id: PhotoID("c"), kind: .legacy)])
    }

    @Test(arguments: [
        "",
        "not json",
        "[]",
        "{}",
        #"{"version":"1","items":[]}"#,
        #"{"version":1,"items":[{"id":"a","kind":"starred"}]}"#,
        #"{"version":1,"items":[{"id":"a","kind":"legacy","since":"yesterday"}]}"#,
    ])
    func anUnreadableFileIsPreservedAndTheNextLoadStartsEmpty(contents: String) async throws {
        let folder = try TemporaryDirectory()
        try write(contents, to: folder.keptURL)
        let store = KeptStore(url: folder.keptURL)

        var preserved: URL?
        do {
            _ = try await store.load()
            Issue.record("Expected KeptStoreError.unreadable")
        } catch KeptStoreError.unreadable(let url) {
            preserved = url
        }
        let copy = try #require(preserved)
        #expect(try Data(contentsOf: copy) == Data(contents.utf8))
        #expect(copy.deletingLastPathComponent() == folder.keptURL.deletingLastPathComponent())
        #expect(copy.lastPathComponent.hasPrefix("kept.unreadable-"))
        #expect(copy.pathExtension == "json")
        #expect(try await store.load().items.isEmpty)
    }

    @Test func aNewerFileIsLeftUntouched() async throws {
        let folder = try TemporaryDirectory()
        let contents = #"{"version":2,"entries":[]}"#
        try write(contents, to: folder.keptURL)

        await #expect(throws: KeptStoreError.unsupportedVersion(2)) {
            try await KeptStore(url: folder.keptURL).load()
        }
        #expect(try Data(contentsOf: folder.keptURL) == Data(contents.utf8))
        #expect(try folder.contents(of: folder.keptURL.deletingLastPathComponent()) == ["kept.json"])
    }

    @Test func aFolderInPlaceOfTheFileIsAnError() async throws {
        let folder = try TemporaryDirectory()
        try FileManager.default.createDirectory(at: folder.keptURL, withIntermediateDirectories: true)

        await #expect(throws: (any Error).self) {
            try await KeptStore(url: folder.keptURL).load()
        }
        #expect(FileManager.default.fileExists(atPath: folder.keptURL.path(percentEncoded: false)))
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}
