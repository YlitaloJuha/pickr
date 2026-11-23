import Foundation
import Testing
@testable import PickrCore

@Suite("Savings")
struct SavingsTests {
    private let moment = Moment(photos: [Make.record(0, id: "a"), Make.record(1, id: "b"), Make.record(2, id: "c")])

    @Test func keepOneIsTotalMinusLargest() {
        let sizes: SizeTable = [PhotoID("a"): 2_000, PhotoID("b"): 5_000, PhotoID("c"): 1_000]
        #expect(Savings.keepOneEstimate(for: moment, sizes: sizes) == ByteEstimate(bytes: 3_000, isApproximate: false))
    }

    @Test func keepOneWithAnUnknownSizeIsAnApproximateLowerBound() {
        let sizes: SizeTable = [PhotoID("a"): 2_000, PhotoID("c"): 1_000]
        let estimate = Savings.keepOneEstimate(for: moment, sizes: sizes)
        #expect(estimate == ByteEstimate(bytes: 1_000, isApproximate: true))
        // Whatever the unknown size turns out to be, the true figure is at least the estimate.
        for unknown in [Int64(0), 500, 1_500, 9_000] {
            var resolved = sizes
            resolved[PhotoID("b")] = unknown
            #expect(Savings.keepOneEstimate(for: moment, sizes: resolved).bytes >= estimate.bytes)
        }
    }

    @Test func keepOneWithNoKnownSizesIsZeroAndApproximate() {
        #expect(Savings.keepOneEstimate(for: moment, sizes: [:]) == ByteEstimate(bytes: 0, isApproximate: true))
    }

    @Test func keepOneOfEqualSizesKeepsJustOne() {
        let sizes: SizeTable = [PhotoID("a"): 7, PhotoID("b"): 7, PhotoID("c"): 7]
        #expect(Savings.keepOneEstimate(for: moment, sizes: sizes).bytes == 14)
    }

    @Test func totalSumsKnownSizes() {
        let sizes: SizeTable = [PhotoID("a"): 2_000, PhotoID("b"): 5_000]
        #expect(Savings.total(of: Make.ids("a", "b"), sizes: sizes) == ByteEstimate(bytes: 7_000, isApproximate: false))
        #expect(Savings.total(of: Set(Make.ids("a", "b")), sizes: sizes).bytes == 7_000)
    }

    @Test func totalWithAnUnknownSizeIsApproximate() {
        let sizes: SizeTable = [PhotoID("a"): 2_000]
        #expect(Savings.total(of: Make.ids("a", "z"), sizes: sizes) == ByteEstimate(bytes: 2_000, isApproximate: true))
    }

    @Test func totalOfNothingIsExactlyZero() {
        #expect(Savings.total(of: [PhotoID](), sizes: [:]) == .zero)
    }

    @Test func sumPropagatesApproximation() {
        let exact = ByteEstimate(bytes: 10, isApproximate: false)
        let about = ByteEstimate(bytes: 5, isApproximate: true)
        #expect(Savings.sum([exact, exact]) == ByteEstimate(bytes: 20, isApproximate: false))
        #expect(Savings.sum([exact, about]) == ByteEstimate(bytes: 15, isApproximate: true))
        #expect(Savings.sum([]) == .zero)
    }
}

@Suite("Selection")
struct SelectionTests {
    private let moment = Moment(photos: [
        Make.record(0, id: "a"),
        Make.record(1, id: "b", favorite: true),
        Make.record(2, id: "c"),
        Make.record(3, id: "d", rating: 4),
    ])

    @Test func nothingIsPreselectedWithoutProtection() {
        #expect(Selection.initial(for: moment, protectFavorites: false).kept.isEmpty)
    }

    @Test func protectedPhotosStartKept() {
        #expect(Selection.initial(for: moment, protectFavorites: true).kept == Set(Make.ids("b", "d")))
    }

    @Test func toggleKeepsAndUnkeeps() {
        var selection = Selection()
        selection.toggle(PhotoID("a"))
        #expect(selection.kept == [PhotoID("a")])
        selection.toggle(PhotoID("c"))
        selection.toggle(PhotoID("a"))
        #expect(selection.kept == [PhotoID("c")])
    }

    @Test func invertSwapsWithinTheMoment() {
        var selection = Selection(kept: Set(Make.ids("a", "c", "gone")))
        selection.invert(in: moment)
        #expect(selection.kept == Set(Make.ids("b", "d")))
        selection.invert(in: moment)
        #expect(selection.kept == Set(Make.ids("a", "c")))
    }

    @Test func selectAllAndClear() {
        var selection = Selection(kept: [PhotoID("gone")])
        selection.selectAll(in: moment)
        #expect(selection.kept == Set(moment.photoIDs))
        selection.clear()
        #expect(selection.kept.isEmpty)
    }

    @Test func restrictDropsIDsThatLeftTheMoment() {
        var selection = Selection(kept: Set(Make.ids("a", "gone", "d")))
        selection.restrict(to: moment)
        #expect(selection.kept == Set(Make.ids("a", "d")))
    }

    @Test func outcomeIsUndecidedUntilSomethingIsKept() {
        #expect(Selection().outcome(in: moment) == .undecided)
        #expect(Selection(kept: [PhotoID("gone")]).outcome(in: moment) == .undecided)
    }

    @Test func outcomeIsPartialInCaptureOrder() {
        let selection = Selection(kept: Set(Make.ids("d", "b")))
        #expect(selection.outcome(in: moment) == .partial(keep: Make.ids("b", "d"), delete: Make.ids("a", "c")))
    }

    @Test func outcomeIsKeepAllWhenEveryMemberIsKept() {
        var selection = Selection(kept: [PhotoID("gone")])
        selection.selectAll(in: moment)
        #expect(selection.outcome(in: moment) == .keepAll)
        selection.toggle(PhotoID("c"))
        #expect(selection.outcome(in: moment) == .partial(keep: Make.ids("a", "b", "d"), delete: [PhotoID("c")]))
    }

    /// A library change shrank the moment: the outcome only ever names current members.
    @Test func outcomeIgnoresFormerMembers() {
        let selection = Selection(kept: Set(Make.ids("a", "c")))
        let shrunk = Moment(photos: [Make.record(0, id: "a"), Make.record(1, id: "b")])
        #expect(selection.outcome(in: shrunk) == .partial(keep: [PhotoID("a")], delete: [PhotoID("b")]))
    }
}
