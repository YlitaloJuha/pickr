import Foundation
import Testing
@testable import PickrCore

// Created by WP0 to lock the frozen contract types (§4.3). Owned by WP1 from here on.

@Suite("Contracts")
struct ContractsTests {
    private func record(_ id: String, _ seconds: TimeInterval, favorite: Bool = false, rating: Int = 0) -> AssetRecord {
        AssetRecord(id: PhotoID(id), created: Date(timeIntervalSince1970: seconds), isFavorite: favorite, rating: rating)
    }

    @Test func photoIDCodesAsASingleString() throws {
        let ids = [PhotoID("A/L0/001"), PhotoID("B/L0/001")]
        let data = try JSONEncoder().encode(ids)
        #expect(String(decoding: data, as: UTF8.self) == #"["A\/L0\/001","B\/L0\/001"]"#)
        #expect(try JSONDecoder().decode([PhotoID].self, from: data) == ids)
    }

    @Test func momentOrdersPhotosAndAnchorsOnTheEarliest() {
        let moment = Moment(photos: [record("c", 20), record("b", 10), record("a", 10)])
        #expect(moment.photoIDs == [PhotoID("a"), PhotoID("b"), PhotoID("c")])
        #expect(moment.id == MomentID(anchor: PhotoID("a")))
        #expect(moment.start == Date(timeIntervalSince1970: 10))
        #expect(moment.end == Date(timeIntervalSince1970: 20))
        #expect(moment.count == 3)
    }

    @Test func protectedMeansFavoriteOrRated() {
        let moment = Moment(photos: [record("a", 1, favorite: true), record("b", 2, rating: 3), record("c", 3)])
        #expect(moment.protectedIDs == [PhotoID("a"), PhotoID("b")])
    }

    @Test(arguments: [(5, 10), (10, 10), (45, 45), (7200, 7200), (99_999, 7200)])
    func timeWindowClamps(input: Int, expected: Int) {
        #expect(TimeWindow(seconds: input, isCustom: true).seconds == expected)
    }

    @Test func nonPresetWindowIsAlwaysCustom() {
        #expect(TimeWindow(seconds: 45, isCustom: false).isCustom)
        #expect(!TimeWindow(seconds: 60, isCustom: false).isCustom)
        #expect(TimeWindow(seconds: 60, isCustom: true).isCustom)
        #expect(TimeWindow.default == TimeWindow(seconds: 60, isCustom: false))
    }

    @Test func timeWindowDecodingClamps() throws {
        let json = Data(#"{"seconds":99999,"isCustom":false}"#.utf8)
        let window = try JSONDecoder().decode(TimeWindow.self, from: json)
        #expect(window == TimeWindow(seconds: 7200, isCustom: true))
    }

    @Test func customRangeSwapsInvertedDates() {
        let early = Date(timeIntervalSince1970: 0)
        let late = Date(timeIntervalSince1970: 100)
        let range = CustomRange(late, early)
        #expect(range.start == early)
        #expect(range.end == late)
    }

    @Test func scanRangePresetRawValuesAreFrozen() {
        #expect(ScanRangePreset.allCases.map(\.rawValue) == ["d7", "d14", "d30", "all", "custom"])
        #expect(MomentOrder.allCases.map(\.rawValue) == ["newest", "mostSpace"])
    }

    @Test func defaults() {
        #expect(GroupingSettings.default.window == .default)
        #expect(GroupingSettings.default.range == ScanRange(preset: .d30))
        #expect(GroupingSettings.default.order == .newest)
        #expect(MomentList.empty.moments.isEmpty)
        #expect(MomentList.empty.savings == .zero)
    }
}
