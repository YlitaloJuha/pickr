import Foundation
import Testing
import PickrTestSupport
@testable import PickrCore

@Suite("DensityHistogram")
struct DensityHistogramTests {
    private let helsinki = Make.calendar("Europe/Helsinki")

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        Make.date(year, month, day, hour, in: helsinki)
    }

    @Test func noDatesGiveNoBuckets() {
        #expect(DensityHistogram.buckets(dates: [], calendar: helsinki).isEmpty)
    }

    @Test func oneDateGivesItsMonth() {
        let buckets = DensityHistogram.buckets(dates: [date(2026, 4, 12)], calendar: helsinki)
        #expect(buckets == [DensityBucket(start: date(2026, 4, 1, 0), end: date(2026, 5, 1, 0), count: 1)])
    }

    @Test func monthlyBucketsAreContiguousAndIncludeEmptyMonths() {
        let dates = [date(2026, 1, 31), date(2026, 1, 2), date(2026, 4, 1, 0), date(2026, 4, 30, 23), date(2026, 2, 14)]
        let buckets = DensityHistogram.buckets(dates: dates, calendar: helsinki)
        #expect(buckets.map(\.start) == [1, 2, 3, 4].map { date(2026, $0, 1, 0) })
        #expect(buckets.map(\.count) == [2, 1, 0, 2])
        for (bucket, next) in zip(buckets, buckets.dropFirst()) {
            #expect(bucket.end == next.start)
        }
        #expect(buckets.last?.end == date(2026, 5, 1, 0))
        #expect(buckets.map(\.id) == buckets.map(\.start))
    }

    /// Month boundaries follow the calendar's time zone: 23:30 UTC on 31 March is already
    /// 1 April in Helsinki.
    @Test func boundariesFollowTheCalendarTimeZone() {
        let utc = Make.calendar("UTC")
        let instant = Make.date(2026, 3, 31, 23, 30, 0, in: utc)
        #expect(DensityHistogram.buckets(dates: [instant], calendar: utc).first?.start == Make.date(2026, 3, 1, in: utc))
        #expect(DensityHistogram.buckets(dates: [instant], calendar: helsinki).first?.start == date(2026, 4, 1, 0))
    }

    @Test func aDateOnABoundaryBelongsToTheLaterBucket() {
        let buckets = DensityHistogram.buckets(dates: [date(2026, 1, 15), date(2026, 2, 1, 0)], calendar: helsinki)
        #expect(buckets.map(\.count) == [1, 1])
    }

    /// v1 rule (`DensityPlotViewModel.swift:61-73`): three or more whole years from the
    /// earliest to the latest photo switch to yearly buckets.
    @Test func justUnderThreeYearsIsMonthly() {
        let buckets = DensityHistogram.buckets(dates: [date(2020, 1, 15), date(2023, 1, 15, 11)], calendar: helsinki)
        #expect(buckets.count == 37) // Jan 2020 … Jan 2023
        #expect(buckets.first?.start == date(2020, 1, 1, 0))
        #expect(buckets.last?.start == date(2023, 1, 1, 0))
        #expect(buckets.map(\.count).reduce(0, +) == 2)
    }

    @Test func threeYearsIsYearly() {
        let buckets = DensityHistogram.buckets(dates: [date(2023, 1, 15), date(2020, 1, 15), date(2021, 6, 1)], calendar: helsinki)
        #expect(buckets.map(\.start) == [2020, 2021, 2022, 2023].map { date($0, 1, 1, 0) })
        #expect(buckets.map(\.count) == [1, 1, 0, 1])
        #expect(buckets.last?.end == date(2024, 1, 1, 0))
    }

    @Test func countsAddUpForALargeLibrary() {
        let records = Fixtures.syntheticLibrary(count: 5_000, seed: 11)
        let buckets = DensityHistogram.buckets(dates: records.map(\.created).reversed(), calendar: helsinki)
        #expect(buckets.map(\.count).reduce(0, +) == 5_000)
        for record in records.prefix(200) {
            let containing = buckets.filter { $0.start <= record.created && record.created < $0.end }
            #expect(containing.count == 1)
        }
    }
}
