import CoreGraphics

/// Which item of a scrolling list or grid is the most visible one, for the ambient background
/// (blueprint §3.5): the item whose frame contains a horizontal line 40 % down the scroll
/// viewport, else the item nearest to that line. Several tiles of a grid row contain the line;
/// the one nearest the viewport's horizontal centre wins. Pure geometry (`ScrollFocus` feeds it).
nonisolated enum FocusLine {
    /// Where the line sits, as a fraction of the viewport's height from its top.
    static let fraction: CGFloat = 0.4

    /// The focused item among `frames`, measured in the same coordinate space as `viewport`.
    /// Ranked by vertical distance to the line (0 when the frame contains it), then horizontal
    /// distance to the viewport's centre, then the higher and the further left frame. `nil` for
    /// an empty viewport or no usable frame (empty, null or not finite).
    static func focusedID<ID: Hashable>(
        in frames: [ID: CGRect],
        viewport: CGRect,
        fraction: CGFloat = fraction
    ) -> ID? {
        guard isUsable(viewport) else { return nil }
        let lineY = viewport.minY + viewport.height * fraction
        let centerX = viewport.midX
        var best: (id: ID, rank: (CGFloat, CGFloat, CGFloat, CGFloat))?
        for (id, frame) in frames where isUsable(frame) {
            let rank = (
                distance(from: lineY, to: frame.minY...frame.maxY),
                distance(from: centerX, to: frame.minX...frame.maxX),
                frame.minY,
                frame.minX
            )
            if let current = best, current.rank <= rank { continue }
            best = (id, rank)
        }
        return best?.id
    }

    /// 0 inside `range`, otherwise the distance to its nearer end.
    private static func distance(from value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        if value < range.lowerBound { return range.lowerBound - value }
        if value > range.upperBound { return value - range.upperBound }
        return 0
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.width > 0 && rect.height > 0
            && rect.minX.isFinite && rect.minY.isFinite && rect.maxX.isFinite && rect.maxY.isFinite
    }
}
