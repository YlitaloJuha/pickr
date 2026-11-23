import CoreGraphics
import Testing
@testable import Pickr

/// The focus line that picks the ambient background's photo (blueprint §3.5).
@Suite("Focus line")
struct FocusLineTests {
    /// A 400 × 1000 pt viewport: the line sits at y = 400.
    let viewport = CGRect(x: 0, y: 0, width: 400, height: 1000)

    /// Full-width rows `height` tall, `gap` apart, starting at `top`.
    func rows(_ count: Int, top: CGFloat, height: CGFloat, gap: CGFloat = 8) -> [Int: CGRect] {
        Dictionary(uniqueKeysWithValues: (0..<count).map { index in
            (index, CGRect(x: 16, y: top + CGFloat(index) * (height + gap), width: 368, height: height))
        })
    }

    @Test func picksTheRowThatContainsTheLine() {
        // Rows at 100–300, 308–508, 516–716: the second contains y = 400.
        #expect(FocusLine.focusedID(in: rows(3, top: 100, height: 200), viewport: viewport) == 1)
    }

    @Test func picksTheNearestRowWhenTheLineFallsInAGap() {
        // Rows at 100–396 and 420–716: 4 pt to the first, 20 pt to the second.
        #expect(FocusLine.focusedID(in: rows(2, top: 100, height: 296, gap: 24), viewport: viewport) == 0)
        // Rows at 100–380 and 404–684: 20 pt to the first, 4 pt to the second.
        #expect(FocusLine.focusedID(in: rows(2, top: 100, height: 280, gap: 24), viewport: viewport) == 1)
    }

    @Test func picksTheNearestRowWhenNoneReachesTheLine() {
        // A header pushes the only rows below the line; rows above it scrolled away.
        #expect(FocusLine.focusedID(in: rows(2, top: 600, height: 150), viewport: viewport) == 0)
        #expect(FocusLine.focusedID(in: rows(2, top: -500, height: 150), viewport: viewport) == 1)
    }

    @Test func picksTheMiddleTileOfAGridRow() {
        // Three columns: the row at 300–420 holds tiles 3, 4 and 5; tile 4 spans the centre.
        let side: CGFloat = 120
        let frames = Dictionary(uniqueKeysWithValues: (0..<9).map { index in
            let origin = CGPoint(x: 16 + CGFloat(index % 3) * (side + 4), y: 176 + CGFloat(index / 3) * (side + 4))
            return (index, CGRect(origin: origin, size: CGSize(width: side, height: side)))
        })
        #expect(FocusLine.focusedID(in: frames, viewport: viewport) == 4)
    }

    @Test func breaksTiesTowardTheLeadingTile() {
        // Four columns with the centre in the gap between tiles 1 and 2: the leading one wins.
        let frames = Dictionary(uniqueKeysWithValues: (0..<4).map { index in
            (index, CGRect(x: CGFloat(index) * 100 + 2, y: 350, width: 96, height: 96))
        })
        #expect(FocusLine.focusedID(in: frames, viewport: viewport) == 1)
    }

    @Test func measuresTheLineFromTheViewportsOwnFrame() {
        // A viewport 200 pt down the shared space: the line is at 200 + 0.4 × 500 = 400.
        let offset = CGRect(x: 0, y: 200, width: 400, height: 500)
        let frames: [String: CGRect] = [
            "above": CGRect(x: 0, y: 250, width: 400, height: 100),
            "on": CGRect(x: 0, y: 360, width: 400, height: 100),
        ]
        #expect(FocusLine.focusedID(in: frames, viewport: offset) == "on")
    }

    @Test func ignoresUnusableInput() {
        #expect(FocusLine.focusedID(in: [Int: CGRect](), viewport: viewport) == nil)
        #expect(FocusLine.focusedID(in: rows(3, top: 100, height: 200), viewport: .zero) == nil)
        #expect(FocusLine.focusedID(in: rows(3, top: 100, height: 200), viewport: .null) == nil)
        let frames: [Int: CGRect] = [
            0: .zero,
            1: .null,
            2: .infinite,
            3: CGRect(x: 0, y: 900, width: 400, height: 50),
        ]
        #expect(FocusLine.focusedID(in: frames, viewport: viewport) == 3)
    }
}

/// `ScrollFocus` publishes only changes of the focused item.
@Suite("Scroll focus")
@MainActor
struct ScrollFocusTests {
    @Test func changesOnlyWhenAnotherItemTakesTheLine() {
        let focus = ScrollFocus<Int>()
        #expect(focus.focused == nil)
        focus.setFrame(CGRect(x: 0, y: 300, width: 400, height: 200), for: 1)
        #expect(focus.focused == nil)  // no viewport yet
        focus.setViewport(CGRect(x: 0, y: 0, width: 400, height: 1000))
        #expect(focus.focused == 1)
        focus.setFrame(CGRect(x: 0, y: 508, width: 400, height: 200), for: 2)
        #expect(focus.focused == 1)
        // Scrolling up by 150 pt brings item 2 onto the line.
        focus.setFrame(CGRect(x: 0, y: 150, width: 400, height: 200), for: 1)
        focus.setFrame(CGRect(x: 0, y: 358, width: 400, height: 200), for: 2)
        #expect(focus.focused == 2)
    }

    @Test func dropsItemsThatDisappearAndKeepsTheLastFocusWhenNoneAreLeft() {
        let focus = ScrollFocus<Int>()
        focus.setViewport(CGRect(x: 0, y: 0, width: 400, height: 1000))
        focus.setFrame(CGRect(x: 0, y: 300, width: 400, height: 200), for: 1)
        focus.setFrame(CGRect(x: 0, y: 600, width: 400, height: 200), for: 2)
        #expect(focus.focused == 1)
        focus.remove(1)
        #expect(focus.focused == 2)
        focus.remove(2)
        #expect(focus.focused == 2)
    }
}

/// The photo strip behind the lists (blueprint §3.5).
@Suite("Ambient strip layout")
struct AmbientStripLayoutTests {
    let canvas = CGRect(x: 0, y: 0, width: 400, height: 1000)

    /// Rows 200 pt tall centred at `centers`, keyed by their position.
    func rows(_ centers: [CGFloat], offset: CGFloat = 0) -> [AmbientStripLayout.Row<Int>] {
        let frames = Dictionary(uniqueKeysWithValues: centers.enumerated().map { index, center in
            (index, CGRect(x: 16, y: center - 100 + offset, width: 368, height: 200))
        })
        return AmbientStripLayout.rows(frames)
    }

    /// The segment's opacity at canvas height `y`: 0 outside its rect, else its mask.
    func opacity(_ segment: AmbientStripLayout.Segment<Int>, at y: CGFloat) -> CGFloat {
        guard y >= segment.rect.minY, y <= segment.rect.maxY else { return 0 }
        guard let low = segment.mask.first, let high = segment.mask.last else { return 1 }
        let unit = (y - segment.rect.minY) / segment.rect.height
        if unit <= low.location { return low.opacity }
        if unit >= high.location { return high.opacity }
        return low.opacity + (high.opacity - low.opacity) * (unit - low.location) / (high.location - low.location)
    }

    @Test func ordersRowsByCentreAndDropsUnusableFrames() {
        let frames: [String: CGRect] = [
            "low": CGRect(x: 0, y: 600, width: 400, height: 200),
            "high": CGRect(x: 0, y: 100, width: 400, height: 200),
            "empty": .zero,
            "null": .null,
        ]
        #expect(AmbientStripLayout.rows(frames).map(\.id) == ["high", "low"])
    }

    @Test func centresEachPhotoOnItsRowAndRampsIntoTheNext() {
        let segments = AmbientStripLayout.segments(rows: rows([200, 450, 700, 950]), canvas: canvas)
        #expect(segments.map(\.id) == [0, 1, 2, 3])
        #expect(segments[0].rect == CGRect(x: 0, y: -300, width: 400, height: 1000))
        #expect(segments[0].mask.isEmpty)
        #expect(segments[1].rect == CGRect(x: 0, y: -50, width: 400, height: 1000))
        #expect(segments[1].mask == [
            AmbientStripLayout.MaskStop(location: 0.25, opacity: 0),
            AmbientStripLayout.MaskStop(location: 0.5, opacity: 1),
        ])
        // Photo 1 is fully in at row 1's centre, half way in between the centres, out at row 0's.
        #expect(opacity(segments[1], at: 450) == 1)
        #expect(opacity(segments[1], at: 325) == 0.5)
        #expect(opacity(segments[1], at: 200) == 0)
    }

    @Test func coversEveryPointOfTheCanvasWithAnOpaquePhoto() {
        for centers in [[200, 450, 700, 950], [-80, 300, 520, 1300], [700, 950], [50, 300], [500], [-400, 1400]] as [[CGFloat]] {
            let segments = AmbientStripLayout.segments(rows: rows(centers), canvas: canvas)
            for y in stride(from: CGFloat(0), through: 1000, by: 5) {
                #expect(segments.contains { opacity($0, at: y) >= 0.999 }, "gap at \(y) for \(centers)")
            }
        }
    }

    @Test func drawsOnlyTheRowsOnScreenAndOneOnEachSide() {
        let centers: [CGFloat] = [-600, -350, -100, 150, 400, 650, 900, 1150, 1400]
        let segments = AmbientStripLayout.segments(rows: rows(centers), canvas: canvas)
        #expect(segments.map(\.id) == [2, 3, 4, 5, 6, 7])
        #expect(segments.first?.mask.isEmpty == true)
    }

    @Test func extendsTheFirstPhotoToTheTopAndTheLastToTheBottom() {
        let low = AmbientStripLayout.segments(rows: rows([700, 950]), canvas: canvas)
        #expect(low[0].rect.minY == 0)
        let high = AmbientStripLayout.segments(rows: rows([50, 300]), canvas: canvas)
        #expect(high[1].rect.maxY == 1000)
    }

    @Test func movesOneToOneWithTheRowsInTheCanvasSpace() {
        let shifted = CGRect(x: 0, y: 120, width: 400, height: 1000)
        let before = AmbientStripLayout.segments(rows: rows([200, 450, 700, 950], offset: 120), canvas: shifted)
        let after = AmbientStripLayout.segments(rows: rows([170, 420, 670, 920], offset: 120), canvas: shifted)
        #expect(before[1].rect.minY == -50)
        #expect(zip(before, after).allSatisfy { pair in pair.0.rect.minY - pair.1.rect.minY == 30 })
    }

    @Test func standsInWithTheNearestPhotoAboveFirst() {
        let available: Set<Int> = [0, 4]
        #expect(AmbientStripLayout.substitute(for: 2, count: 5) { available.contains($0) } == 0)
        #expect(AmbientStripLayout.substitute(for: 3, count: 5) { available.contains($0) } == 4)
        #expect(AmbientStripLayout.substitute(for: 1, count: 5) { _ in false } == nil)
        #expect(AmbientStripLayout.substitute(for: 0, count: 1) { _ in true } == nil)
    }
}

/// The blurred photos keep primary text legible over any photo (blueprint §3.5).
@Suite("Ambient palette")
struct AmbientPaletteTests {
    /// Average colours across the HSL space.
    static let averages: [AmbientPalette.RGB] = (0...24).flatMap { hue in
        (0...10).flatMap { saturation in
            (0...10).map { lightness in
                AmbientPalette.rgb(from: AmbientPalette.HSL(
                    hue: Double(hue) / 24,
                    saturation: Double(saturation) / 10,
                    lightness: Double(lightness) / 10
                ))
            }
        }
    }

    /// Black under black text in light, white under white text in dark.
    static func worstPixel(_ appearance: AmbientPalette.Appearance) -> AmbientPalette.RGB {
        appearance == .light ? AmbientPalette.RGB(red: 0, green: 0, blue: 0) : AmbientPalette.RGB(red: 1, green: 1, blue: 1)
    }

    @Test(arguments: [AmbientPalette.Appearance.light, .dark])
    func primaryTextKeepsItsContrastOverTheWorstRegion(_ appearance: AmbientPalette.Appearance) {
        let text = AmbientPalette.primaryText(for: appearance)
        let worst = Self.averages.map { average in
            AmbientPalette.contrastRatio(
                AmbientPalette.photoComposite(Self.worstPixel(appearance), average: average, for: appearance),
                text
            )
        }.min() ?? 0
        #expect(worst >= AmbientPalette.minimumTextContrast)
        // The figure documented in AmbientPalette.swift (5.62 light, 5.58 dark).
        #expect(worst > 5.5)
    }

    @Test(arguments: [AmbientPalette.Appearance.light, .dark])
    func blendedStripSegmentsKeepTheContrast(_ appearance: AmbientPalette.Appearance) {
        let pixel = Self.worstPixel(appearance)
        let text = AmbientPalette.primaryText(for: appearance)
        let tints = Self.averages.map { AmbientPalette.photoTint($0, for: appearance) }
        let hardest = tints.sorted {
            AmbientPalette.contrastRatio(AmbientPalette.composite(pixel, tint: $0, for: appearance), text)
                < AmbientPalette.contrastRatio(AmbientPalette.composite(pixel, tint: $1, for: appearance), text)
        }.prefix(40)
        var worst = Double.infinity
        for first in hardest {
            for second in tints {
                for weight in [0.25, 0.5, 0.75] {
                    let tint = AmbientPalette.mix(first, second, weight: weight)
                    worst = min(worst, AmbientPalette.contrastRatio(AmbientPalette.composite(pixel, tint: tint, for: appearance), text))
                }
            }
        }
        #expect(worst > 5.5)
    }
}
