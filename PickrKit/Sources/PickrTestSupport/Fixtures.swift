import Foundation
import PickrCore

/// Shared test data: the capture timeline of the 40 files in test-photos/, and
/// deterministic synthetic libraries for property and performance tests (§4.8, DNA §7.1).
public nonisolated enum Fixtures {
    // MARK: - test-photos/

    /// One themed burst of test photos, `testPhotoSpacing` seconds apart.
    public nonisolated struct PhotoGroup: Hashable, Sendable {
        /// The file-name stem: photos are `<name>_1.jpg` … `<name>_<count>.jpg`.
        public let name: String
        public let count: Int
        /// Seconds from the previous group's last photo to this group's first; 0 for the first.
        public let gapBefore: Int

        public init(name: String, count: Int, gapBefore: Int) {
            self.name = name
            self.count = count
            self.gapBefore = gapBefore
        }
    }

    /// The ten groups in capture order. The real gaps are 93/123/48/183/23/153/38/203/63 s
    /// (`CLAUDE.md` in v1 listed them 3 s short).
    public static let testPhotoGroups: [PhotoGroup] = [
        PhotoGroup(name: "beach", count: 3, gapBefore: 0),
        PhotoGroup(name: "sunset", count: 5, gapBefore: 93),
        PhotoGroup(name: "garden", count: 4, gapBefore: 123),
        PhotoGroup(name: "portrait", count: 3, gapBefore: 48),
        PhotoGroup(name: "food", count: 6, gapBefore: 183),
        PhotoGroup(name: "ocean", count: 4, gapBefore: 23),
        PhotoGroup(name: "city", count: 3, gapBefore: 153),
        PhotoGroup(name: "pet", count: 5, gapBefore: 38),
        PhotoGroup(name: "flowers", count: 4, gapBefore: 203),
        PhotoGroup(name: "snow", count: 3, gapBefore: 63),
    ]

    /// Seconds between consecutive photos inside a group.
    public static let testPhotoSpacing = 3

    /// The first photo's EXIF `DateTimeOriginal`, 2026-04-12 09:37:18, read as UTC.
    ///
    /// The files carry no `OffsetTimeOriginal`, so on a device Photos reads them in the
    /// device's time zone. Only the gaps matter for grouping.
    public static let testPhotosStart = Date(timeIntervalSince1970: 1_775_986_638)

    /// The ID used for one test photo: its file-name stem, for example `beach_1`.
    public static func testPhotoID(_ name: String, _ number: Int) -> PhotoID {
        PhotoID("\(name)_\(number)")
    }

    /// The 40 test photos as records, in capture order.
    public static var testPhotos: [AssetRecord] {
        var records: [AssetRecord] = []
        var offset = 0 // seconds after `testPhotosStart`
        for group in testPhotoGroups {
            offset += group.gapBefore
            for number in 1...group.count {
                if number > 1 { offset += testPhotoSpacing }
                records.append(AssetRecord(
                    id: testPhotoID(group.name, number),
                    created: testPhotosStart.addingTimeInterval(TimeInterval(offset))
                ))
            }
        }
        return records
    }

    /// The byte size of each test photo file (about 117 KB each).
    public static let testPhotoSizes: SizeTable = {
        let bytes: [String: [Int64]] = [
            "beach": [117_108, 116_892, 117_048],
            "sunset": [116_893, 117_010, 116_948, 117_095, 116_892],
            "garden": [116_984, 117_064, 116_974, 117_040],
            "portrait": [117_025, 117_020, 116_953],
            "food": [116_927, 117_007, 116_953, 117_053, 116_925, 116_943],
            "ocean": [116_974, 117_010, 116_949, 116_968],
            "city": [116_965, 116_930, 116_942],
            "pet": [116_963, 117_032, 116_954, 116_957, 117_063],
            "flowers": [116_913, 116_890, 116_952, 117_042],
            "snow": [116_983, 116_998, 116_956],
        ]
        var table: SizeTable = [:]
        for (name, sizes) in bytes {
            for (index, size) in sizes.enumerated() {
                table[testPhotoID(name, index + 1)] = size
            }
        }
        return table
    }()

    /// Moment sizes per window in seconds, in capture order (DNA §7.1). Windows of 203 s and
    /// more merge everything into one moment of 40.
    public static let testPhotoMomentSizes: [Int: [Int]] = [
        10: [3, 5, 4, 3, 6, 4, 3, 5, 4, 3],
        30: [3, 5, 4, 3, 10, 3, 5, 4, 3],
        60: [3, 5, 7, 10, 8, 4, 3],
        180: [15, 18, 7],
        240: [40],
    ]

    // MARK: - Synthetic libraries

    /// A small, fast, deterministic generator (SplitMix64), so randomized tests repeat exactly.
    public nonisolated struct SeededGenerator: RandomNumberGenerator, Sendable {
        private var state: UInt64

        public init(seed: UInt64) {
            state = seed
        }

        public mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A library of `count` records in capture order, shaped like a camera roll: mostly bursts
    /// seconds apart, some photos minutes apart, occasional gaps of hours or days, and a few
    /// exact duplicates of a capture time (to exercise the ID tiebreak). About 5 % are
    /// favorites and 3 % rated. IDs are `S<seed>/<index>`, unique within one library.
    public static func syntheticLibrary(count: Int, seed: UInt64, start: Date = testPhotosStart) -> [AssetRecord] {
        var generator = SeededGenerator(seed: seed)
        var records: [AssetRecord] = []
        records.reserveCapacity(max(count, 0))
        var created = start
        for index in 0..<max(count, 0) {
            if index > 0 {
                let roll = Int.random(in: 0..<100, using: &generator)
                let gap: TimeInterval = switch roll {
                case 0..<3: 0
                case 3..<70: TimeInterval(Int.random(in: 1...30, using: &generator))
                case 70..<92: TimeInterval(Int.random(in: 31...900, using: &generator))
                default: TimeInterval(Int.random(in: 901...259_200, using: &generator))
                }
                created = created.addingTimeInterval(gap)
            }
            let favoriteRoll = Int.random(in: 0..<100, using: &generator)
            records.append(AssetRecord(
                id: PhotoID("S\(seed)/\(index)"),
                created: created,
                isFavorite: favoriteRoll < 5,
                rating: (5..<8).contains(favoriteRoll) ? Int.random(in: 1...5, using: &generator) : 0
            ))
        }
        // Equal capture times are ordered by ID, and "S1/10" sorts before "S1/9".
        return records.sorted(by: AssetRecord.inCaptureOrder)
    }

    /// Random known sizes (0.5–12 MB) for about `knownFraction` of `records`; the rest stay unknown.
    public static func syntheticSizes(
        for records: [AssetRecord],
        knownFraction: Double = 1,
        seed: UInt64
    ) -> SizeTable {
        var generator = SeededGenerator(seed: seed)
        var table: SizeTable = [:]
        for record in records where Double.random(in: 0..<1, using: &generator) < knownFraction {
            table[record.id] = Int64.random(in: 500_000...12_000_000, using: &generator)
        }
        return table
    }
}
