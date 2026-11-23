import CoreGraphics

/// Lays out the photo strip behind the Moments and Kept lists (blueprint §3.5): each moment's
/// photo sits behind its row and moves with it, and neighbours blend continuously. Pure
/// geometry, so tests can pin it; `AmbientColor.swift` draws the result.
///
/// - Photo *i* is fully opaque at row *i*'s vertical centre and blends linearly into photo
///   *i + 1* by row *i + 1*'s centre. Segments are drawn in painter's order, each over the one
///   before with a top gradient mask, so there is never a gap.
/// - Each photo fills a canvas-sized rect centred on its row, shifted only as far as needed to
///   cover the part of the canvas it shows (the first photo reaches the canvas top, the last
///   the canvas bottom).
/// - Only the rows on screen plus one on each side are drawn: from the last row whose centre is
///   above the canvas to the first row whose centre is below it.
nonisolated enum AmbientStripLayout {
    /// A reported row: its ID and its frame, in the same coordinate space as the canvas.
    struct Row<ID: Hashable> {
        let id: ID
        let frame: CGRect
    }

    /// An opacity stop of a segment's mask, top to bottom over its rect.
    struct MaskStop: Equatable {
        /// 0 at the rect's top, 1 at its bottom.
        let location: CGFloat
        let opacity: CGFloat
    }

    /// One photo of the strip, in painter's order.
    struct Segment<ID: Hashable>: Identifiable, Equatable {
        let id: ID
        /// The row's position in the rows ordered by centre, for finding neighbours.
        let index: Int
        /// Where the photo is drawn, scaled to fill, in canvas coordinates.
        let rect: CGRect
        /// The mask over `rect`; empty when the segment is fully opaque.
        let mask: [MaskStop]
    }

    /// The usable rows of `frames`, ordered by vertical centre.
    static func rows<ID: Hashable>(_ frames: [ID: CGRect]) -> [Row<ID>] {
        frames
            .filter { isUsable($0.value) }
            .map { Row(id: $0.key, frame: $0.value) }
            .sorted { $0.frame.midY < $1.frame.midY }
    }

    /// The segments that cover `canvas`, bottom first. `rows` must be ordered by centre (see
    /// `rows(_:)`) and share the canvas's coordinate space; rects come back relative to the
    /// canvas's origin.
    static func segments<ID: Hashable>(rows: [Row<ID>], canvas: CGRect) -> [Segment<ID>] {
        guard !rows.isEmpty, isUsable(canvas) else { return [] }
        let height = canvas.height
        let centers = rows.map { $0.frame.midY - canvas.minY }
        let first = centers.lastIndex { $0 <= 0 } ?? 0
        let last = centers.firstIndex { $0 >= height } ?? centers.count - 1

        return (first...last).map { index in
            let center = centers[index]
            let top = index == first ? 0 : max(centers[index - 1], 0)
            let bottom = index == last ? height : min(centers[index + 1], height)
            var minY = center - height / 2
            if minY > top { minY = top }
            if minY + height < bottom { minY = bottom - height }
            let rect = CGRect(x: 0, y: minY, width: canvas.width, height: height)
            let mask = index == first
                ? []
                : ramp(from: centers[index - 1], to: center, over: rect)
            return Segment(id: rows[index].id, index: index, rect: rect, mask: mask)
        }
    }

    /// The row whose photo stands in for row `index` while its own isn't available: the
    /// nearest row that has one, the row above first on a tie. `nil` when none has.
    static func substitute(for index: Int, count: Int, isAvailable: (Int) -> Bool) -> Int? {
        guard count > 1 else { return nil }
        for distance in 1..<count {
            if index - distance >= 0, isAvailable(index - distance) { return index - distance }
            if index + distance < count, isAvailable(index + distance) { return index + distance }
        }
        return nil
    }

    /// Opacity 0 at `start` rising linearly to 1 at `end` (both in canvas coordinates), as two
    /// stops over `rect`. Empty when the whole rect is past the ramp.
    private static func ramp(from start: CGFloat, to end: CGFloat, over rect: CGRect) -> [MaskStop] {
        let length = max(end - start, 1)
        func opacity(at y: CGFloat) -> CGFloat { min(max((y - start) / length, 0), 1) }
        func location(of y: CGFloat) -> CGFloat { min(max((y - rect.minY) / rect.height, 0), 1) }
        let low = location(of: start)
        let high = location(of: start + length)
        let stops = [
            MaskStop(location: low, opacity: opacity(at: rect.minY + low * rect.height)),
            MaskStop(location: high, opacity: opacity(at: rect.minY + high * rect.height)),
        ]
        return stops.allSatisfy { $0.opacity >= 1 } ? [] : stops
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.width > 0 && rect.height > 0
            && rect.minX.isFinite && rect.minY.isFinite && rect.maxX.isFinite && rect.maxY.isFinite
    }
}
