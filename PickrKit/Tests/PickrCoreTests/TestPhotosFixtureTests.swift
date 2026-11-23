import Foundation
import ImageIO
import Testing
import PickrTestSupport
@testable import PickrCore

/// The 40 files in test-photos/ (DNA §7.1). The same timeline drives the simulator smoke
/// test (7 moments at 1 min) and the App Store screenshots, so it is locked here.
@Suite("test-photos fixture")
struct TestPhotosFixtureTests {
    private let photos = Fixtures.testPhotos

    @Test func fortyPhotosInCaptureOrderWithUniqueIDs() {
        #expect(photos.count == 40)
        #expect(Set(photos.map(\.id)).count == 40)
        #expect(photos == photos.sorted(by: AssetRecord.inCaptureOrder))
        #expect(photos.first?.id == PhotoID("beach_1"))
        #expect(photos.last?.id == PhotoID("snow_3"))
        #expect(photos.allSatisfy { !$0.isProtected })
        #expect(Set(Fixtures.testPhotoSizes.keys) == Set(photos.map(\.id)))
    }

    @Test func timelineRunsFrom093718To095415() throws {
        let span = try #require(photos.last).created.timeIntervalSince(try #require(photos.first).created)
        #expect(span == 16 * 60 + 57)
        #expect(photos.first?.created == Fixtures.testPhotosStart)
    }

    @Test func gapsBetweenGroupsAreTheRealOnes() {
        let gaps = zip(photos, photos.dropFirst())
            .map { Int($1.created.timeIntervalSince($0.created)) }
            .filter { $0 != Fixtures.testPhotoSpacing }
        #expect(gaps == [93, 123, 48, 183, 23, 153, 38, 203, 63])
        #expect(Fixtures.testPhotoGroups.map(\.count) == [3, 5, 4, 3, 6, 4, 3, 5, 4, 3])
    }

    /// The table in §4.8: 10 s → 10, 30 s → 9, 1 min → 7, 3 min → 3, 4 min → 1.
    @Test(arguments: [(10, 10), (30, 9), (60, 7), (180, 3), (240, 1)])
    func momentCountPerWindow(seconds: Int, count: Int) throws {
        let moments = Clusterer.moments(from: photos, window: TimeWindow(seconds: seconds, isCustom: false))
        #expect(moments.count == count)
        let expected = try #require(Fixtures.testPhotoMomentSizes[seconds])
        #expect(moments.sizesInCaptureOrder == expected)
    }

    @Test func defaultWindowGivesTheSevenNamedMoments() {
        let moments = Clusterer.moments(from: photos, window: .default)
        let firstPhotos = moments.reversed().map(\.id.anchor)
        #expect(firstPhotos == ["beach_1", "sunset_1", "garden_1", "food_1", "city_1", "flowers_1", "snow_1"].map(PhotoID.init))
        let lastPhotos = moments.reversed().map { $0.photoIDs.last }
        #expect(lastPhotos == ["beach_3", "sunset_5", "portrait_3", "ocean_4", "pet_5", "flowers_4", "snow_3"].map(PhotoID.init))
    }

    /// The inclusive boundary on real data: each gap joins at exactly its own length.
    @Test(arguments: [
        (22, [3, 5, 4, 3, 6, 4, 3, 5, 4, 3]),
        (23, [3, 5, 4, 3, 10, 3, 5, 4, 3]),
        (62, [3, 5, 7, 10, 8, 4, 3]),
        (63, [3, 5, 7, 10, 8, 7]),
        (182, [15, 18, 7]),
        (183, [33, 7]),
        (202, [33, 7]),
        (203, [40]),
    ])
    func eachGapJoinsAtExactlyItsLength(seconds: Int, sizes: [Int]) {
        let moments = Clusterer.moments(from: photos, window: TimeWindow(seconds: seconds, isCustom: true))
        #expect(moments.sizesInCaptureOrder == sizes)
    }

    @Test func pipelineOverTheWholeLibraryAtOneMinute() {
        let list = MomentPipeline.build(
            index: photos,
            grouping: GroupingSettings(range: ScanRange(preset: .all)),
            kept: [],
            sizes: Fixtures.testPhotoSizes,
            now: Fixtures.testPhotosStart,
            calendar: Make.calendar("UTC")
        )
        #expect(list.moments.count == 7)
        #expect(list.photoCount == 40)
        #expect(!list.savings.isApproximate)
        #expect(list.savings.bytes > 33 * 116_000 && list.savings.bytes < 33 * 118_000)
    }

    // MARK: - The files themselves

    private static let photosFolder = URL(filePath: #filePath)
        .deletingLastPathComponent() // PickrCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // PickrKit
        .deletingLastPathComponent() // repo root
        .appending(path: "test-photos", directoryHint: .isDirectory)

    private static var hasPhotosFolder: Bool {
        FileManager.default.fileExists(atPath: photosFolder.appending(path: "beach_1.jpg").path(percentEncoded: false))
    }

    /// Every file exists and its EXIF capture time (local wall clock, no offset) matches the
    /// fixture read as UTC, so the fixture can never drift from the committed photos.
    @Test(.enabled(if: hasPhotosFolder, "needs the repo's test-photos folder"))
    func fixtureMatchesTheExifTimesOfTheFiles() throws {
        let style = Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits):\(month: .twoDigits):\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
            timeZone: TimeZone(identifier: "UTC")!,
            calendar: Calendar(identifier: .gregorian)
        )
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.photosFolder.path(percentEncoded: false))
            .filter { $0.hasSuffix(".jpg") }
        #expect(Set(files) == Set(photos.map { "\($0.id.rawValue).jpg" }))

        for record in photos {
            let url = Self.photosFolder.appending(path: "\(record.id.rawValue).jpg")
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
            let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            #expect(original == style.format(record.created), "\(record.id.rawValue)")
        }
    }
}
