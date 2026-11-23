import Foundation
import Testing
@testable import PickrPersistence

@Suite("Stats repository")
struct StatsRepositoryTests {
    private typealias Keys = PersistedKeys.Stats

    private static let now = date(1_795_255_200)

    @Test(arguments: StoreKind.allCases)
    func absentKeysGiveZeroAndWriteTheFirstUseDate(kind: StoreKind) {
        let box = kind.make()
        let stats = StatsRepository(store: box.store).load(now: Self.now)

        #expect(stats == LifetimeStats(photosDeleted: 0, bytesFreed: 0, momentsCleared: 0, firstUse: Self.now))
        #expect(box.snapshot[Keys.firstUseDate] as? Date == Self.now)
        #expect(box.snapshot.count == 1)
    }

    @Test func theFirstUseDateIsWrittenOnce() {
        let store = InMemoryKeyValueStore()
        let repository = StatsRepository(store: store)
        _ = repository.load(now: Self.now)
        let later = repository.load(now: Self.now.addingTimeInterval(86_400))

        #expect(later.firstUse == Self.now)
        #expect(store.values[Keys.firstUseDate] as? Date == Self.now)
    }

    @Test func aFirstUseDateOfTheWrongTypeIsReplaced() {
        let store = InMemoryKeyValueStore([Keys.firstUseDate: "2026-05-14"])
        #expect(StatsRepository(store: store).load(now: Self.now).firstUse == Self.now)
        #expect(store.values[Keys.firstUseDate] as? Date == Self.now)
    }

    @Test(arguments: StoreKind.allCases)
    func readsTheV1Fixture(kind: StoreKind) throws {
        let box = kind.make(try V1Fixture.values())
        let stats = StatsRepository(store: box.store).load(now: Self.now)

        #expect(stats.photosDeleted == 412)
        #expect(stats.bytesFreed == 1_572_864, "Before the migration, the v1 MiB total converted")
        #expect(stats.momentsCleared == 37)
        #expect(stats.firstUse == V1Fixture.firstUseDate)
        #expect(box.snapshot[Keys.bytesFreed] == nil, "Loading never writes bytesFreed")
    }

    @Test func bytesFreedWinsOverTheV1Total() {
        let store = InMemoryKeyValueStore([Keys.bytesFreed: Int64(10), Keys.mbFreed: 1.5])
        #expect(StatsRepository(store: store).load(now: Self.now).bytesFreed == 10)
    }

    struct MiBCase: Sendable, CustomTestStringConvertible {
        let mib: Double
        let bytes: Int64
        var testDescription: String { "\(mib) MiB" }
    }

    @Test(arguments: [
        MiBCase(mib: 1.5, bytes: 1_572_864),
        MiBCase(mib: 0, bytes: 0),
        MiBCase(mib: 1, bytes: 1_048_576),
        MiBCase(mib: 2318.25, bytes: 2_430_861_312),
        MiBCase(mib: 0.000_000_476_837_158_203_125, bytes: 1),   // exactly 0.5 B: rounds away from zero
        MiBCase(mib: 0.000_000_476_837_158_203_124, bytes: 0),
        MiBCase(mib: 3.141_592_653_589_793, bytes: 3_294_199),
        MiBCase(mib: -12, bytes: 0),
        MiBCase(mib: .nan, bytes: 0),
        MiBCase(mib: .infinity, bytes: 0),
        MiBCase(mib: 1e30, bytes: .max),
    ])
    func mebibytesBecomeBytesOnce(_ c: MiBCase) {
        #expect(LegacyStats.bytes(fromMiB: c.mib) == c.bytes)
    }

    @Test func anIntegerMbFreedIsConvertedToo() {
        let store = InMemoryKeyValueStore([Keys.mbFreed: 2])
        #expect(LegacyStats.bytesFreed(in: store) == 2_097_152)
    }

    @Test(arguments: StoreKind.allCases)
    func recordAddsAConfirmedDeletion(kind: StoreKind) throws {
        let box = kind.make(try V1Fixture.values())
        let repository = StatsRepository(store: box.store)
        _ = repository.load(now: Self.now)

        let stats = repository.record(deleted: 3, bytes: 3_000_000, momentCleared: true)
        #expect(stats.photosDeleted == 415)
        #expect(stats.bytesFreed == 1_572_864 + 3_000_000)
        #expect(stats.momentsCleared == 38)
        #expect(stats.firstUse == V1Fixture.firstUseDate)

        #expect(repository.load(now: Self.now) == stats)
        let saved = box.snapshot
        #expect(saved[Keys.photosDeleted] as? Int == 415)
        #expect(saved[Keys.bytesFreed] as? Int64 == 4_572_864)
        #expect(saved[Keys.clustersCleared] as? Int == 38)
        #expect(saved[Keys.mbFreed] as? Double == 1.5, "The v1 total is never written")
    }

    @Test func recordWithoutAMomentLeavesMomentsCleared() {
        let store = RecordingStore([Keys.firstUseDate: Self.now])
        let stats = StatsRepository(store: store).record(deleted: 2, bytes: 500, momentCleared: false)

        #expect(stats.momentsCleared == 0)
        #expect(store.writtenKeys == [Keys.photosDeleted, Keys.bytesFreed])
    }

    @Test(arguments: [(0, Int64(0)), (-4, Int64(-100))])
    func recordIgnoresNothingAndNegatives(deleted: Int, bytes: Int64) {
        let store = RecordingStore([Keys.firstUseDate: Self.now, Keys.photosDeleted: 7])
        let stats = StatsRepository(store: store).record(deleted: deleted, bytes: bytes, momentCleared: false)

        #expect(stats.photosDeleted == 7)
        #expect(stats.bytesFreed == 0)
        #expect(store.writtenKeys.isEmpty)
    }

    @Test func totalsStopAtTheirMaximum() {
        let store = InMemoryKeyValueStore([
            Keys.firstUseDate: Self.now,
            Keys.photosDeleted: Int.max - 1,
            Keys.bytesFreed: Int64.max - 1,
            Keys.clustersCleared: Int.max,
        ])
        let stats = StatsRepository(store: store).record(deleted: 5, bytes: 5, momentCleared: true)

        #expect(stats.photosDeleted == .max)
        #expect(stats.bytesFreed == .max)
        #expect(stats.momentsCleared == .max)
    }

    @Test func recordBeforeAnyLoadWritesAFirstUseDate() {
        let store = InMemoryKeyValueStore()
        let stats = StatsRepository(store: store).record(deleted: 1, bytes: 1, momentCleared: true)
        #expect(store.values[Keys.firstUseDate] as? Date == stats.firstUse)
    }

    /// A deletion recorded while the migration hasn't completed (its Kept save failed)
    /// carries the v1 total forward, and the later migration doesn't convert it again.
    @Test func theV1TotalIsConvertedOnlyOnceWhenADeletionComesFirst() async throws {
        let folder = try TemporaryDirectory()
        let store = try V1Fixture.inMemory()
        let repository = StatsRepository(store: store)
        _ = repository.load(now: Self.now)
        _ = repository.record(deleted: 1, bytes: 100, momentCleared: true)
        #expect(store.values[Keys.bytesFreed] as? Int64 == 1_572_964)

        let report = try await MigrationV1.run(store: store, kept: KeptStore(url: folder.keptURL), now: Self.now)
        #expect(report.bytesFreed == nil)
        #expect(repository.load(now: Self.now).bytesFreed == 1_572_964)
    }
}
