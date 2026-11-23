import SwiftUI

// Layout by space, never by device (ADAPTIVE.md §1, §3.2, §5).
//
// For screen agents:
//
//   ColumnLayout(sizeClass:width:showsList:)   the one stack/split rule: split only when the
//                                              horizontal size class is .regular AND the
//                                              container is ≥ 740 pt wide AND the list shows.
//   ColumnLayoutReader(showsList:) { layout in … }
//                                              measures the container it fills, decides in the
//                                              same layout pass (no stack frame flashes before
//                                              a split) and sets `\.columnLayout` below it.
//                                              Use it at the root of MomentsColumns/KeptColumns;
//                                              to report the layout upward (RootView's bottom
//                                              accessory), add `.onChange(of: layout,
//                                              initial: true)` inside the closure.
//   @Environment(\.columnLayout)               .stack outside a reader. ReviewScreen reads it
//                                              for its three split differences only.
//
//   .readableWidth()                           caps full-width content at 540 pt, centred
//                                              (states, celebration, onboarding, Kept empty).
//   .readableWidth(ReadableWidth.text)         640 pt (How Pickr. Finds Moments), etc.
//   .readableContentMargins()                  for a List/ScrollView in a wide stack: side
//                                              margins that keep the column ≤ 680 pt.
//   ReadableWidth.*                            every cap in one place (toast 480, filmstrip 560,
//                                              onboarding button 420, …).
//
//   CompactHeight.isCompact(verticalSizeClass) true unless the height class is .regular.
//   .hiddenInCompactHeight()                   removes the view when the height is compact
//                                              (the onboarding hero, the One by One filmstrip).
//
// "There is room" is always `== .regular`: a nil size class takes the narrow branch. Never
// read the device, idiom, screen or orientation; measure the container that switches.

/// Whether a tab shows one column (the iPhone stack) or the list beside its detail.
nonisolated enum ColumnLayout: Hashable, Sendable {
    /// One column: `NavigationStack`, Review pushed, the bottom accessory.
    case stack
    /// `NavigationSplitView`: the list beside Review or the Kept moment.
    case split

    /// The narrowest container that splits: a 300 pt sidebar beside a detail that still
    /// fits three 136 pt tiles, plus separators.
    static let splitMinimumWidth: CGFloat = 740

    /// - Parameters:
    ///   - sizeClass: the container's horizontal size class.
    ///   - width: the container's own measured width, in points.
    ///   - showsList: whether the tab shows its list (access granted, ready, at least one
    ///     moment). Every other state is one full-width column.
    init(sizeClass: UserInterfaceSizeClass?, width: CGFloat, showsList: Bool) {
        self = sizeClass == .regular && width >= Self.splitMinimumWidth && showsList ? .split : .stack
    }

    var isSplit: Bool { self == .split }
}

extension EnvironmentValues {
    /// The layout of the enclosing tab container; `.stack` outside a `ColumnLayoutReader`.
    @Entry var columnLayout: ColumnLayout = .stack
}

/// Measures the space it is given and builds its content for the matching `ColumnLayout`,
/// in the same layout pass. It fills the proposed size and sets `\.columnLayout` for its
/// content. Keep state that must survive a stack ↔ split swap (the list's scroll anchor,
/// split visibility) above the reader or in the models.
struct ColumnLayoutReader<Content: View>: View {
    let showsList: Bool
    private let content: (ColumnLayout) -> Content

    @Environment(\.horizontalSizeClass) private var sizeClass

    init(showsList: Bool, @ViewBuilder content: @escaping (ColumnLayout) -> Content) {
        self.showsList = showsList
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = ColumnLayout(sizeClass: sizeClass, width: proxy.size.width, showsList: showsList)
            content(layout)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .environment(\.columnLayout, layout)
                // A swap is never animated, even when the change that caused it is (the last row
                // leaving a list): the old container would cross-fade with the new one.
                .transaction(value: layout) { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
        }
    }
}

// MARK: - Readable widths (§5.1)

/// The widest each kind of content gets, in points. Content narrower than the cap is
/// unaffected; wider windows centre it.
nonisolated enum ReadableWidth {
    /// Full-width states: denied, indexing, failed, celebration, Kept empty, onboarding.
    static let content: CGFloat = 540
    /// The Moments or Kept list in a wide stack (the open Duo turned, a 700 pt window).
    static let cards: CGFloat = 680
    /// Running text: How Pickr. Finds Moments.
    static let text: CGFloat = 640
    /// A bottom call to action with flexible sizing (onboarding, What's New).
    static let button: CGFloat = 420
    /// The One by One filmstrip.
    static let filmstrip: CGFloat = 560
    /// A toast capsule.
    static let toast: CGFloat = 480
}

extension View {
    /// Caps this view at `maxWidth` and centres it in the space it is given. Use it on
    /// full-width content columns, not on scroll views (use `readableContentMargins`).
    func readableWidth(_ maxWidth: CGFloat = ReadableWidth.content, alignment: Alignment = .center) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity, alignment: alignment)
    }

    /// Adds horizontal content margins to a scroll view (`List`, `ScrollView`) so its
    /// content column is at most `maxWidth` wide, centred, while the scroll view itself and
    /// its scroll edge effects still span the full width. The margins come from the scroll
    /// view's own measured width; they are zero when it is narrower than the cap.
    func readableContentMargins(_ maxWidth: CGFloat = ReadableWidth.cards) -> some View {
        modifier(ReadableContentMargins(maxWidth: maxWidth))
    }
}

private struct ReadableContentMargins: ViewModifier {
    let maxWidth: CGFloat

    @State private var margin: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, margin, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { proxy in
                Self.margin(width: proxy.size.width, maxWidth: maxWidth)
            } action: { newMargin in
                margin = newMargin
            }
    }

    /// Half of the width beyond the cap, rounded to whole points.
    nonisolated static func margin(width: CGFloat, maxWidth: CGFloat) -> CGFloat {
        max(0, ((width - maxWidth) / 2).rounded(.down))
    }
}

// MARK: - Compact height (§5.2)

/// Height decisions (ADAPTIVE.md §5.2): with a compact height (a phone in landscape) the
/// onboarding hero and the One by One filmstrip hide. Nothing else changes.
nonisolated enum CompactHeight {
    /// `true` unless the vertical size class is `.regular` (nil counts as compact).
    static func isCompact(_ verticalSizeClass: UserInterfaceSizeClass?) -> Bool {
        verticalSizeClass != .regular
    }
}

extension View {
    /// Removes this view while the vertical size class isn't `.regular`.
    func hiddenInCompactHeight() -> some View {
        modifier(HiddenInCompactHeight())
    }
}

private struct HiddenInCompactHeight: ViewModifier {
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    func body(content: Content) -> some View {
        if !CompactHeight.isCompact(verticalSizeClass) {
            content
        }
    }
}

#if DEBUG
#Preview("Column layout") {
    ColumnLayoutReader(showsList: true) { layout in
        VStack(spacing: Theme.Spacing.medium) {
            Text(verbatim: layout.isSplit ? "Split" : "Stack")
                .font(.largeTitle.bold())
            Text(verbatim: "Readable content column")
                .padding()
                .readableWidth()
                .background(Theme.Palette.card, in: Theme.Shapes.card)
            Image(systemName: "photo.on.rectangle.angled.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .hiddenInCompactHeight()
                .accessibilityHidden(true)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.screen)
    }
}
#endif
