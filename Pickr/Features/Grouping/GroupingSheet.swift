import PickrModels
import SwiftUI

// For the Moments screen (WP7). `router.sheet == .grouping` is the single source of truth.
//
//   Button { router.sheet = .grouping } label: { Label("Adjust", systemImage: "slider.horizontal.3") }
//       .adjustPresentation(zoomNamespace: namespace)
//   … and on that ToolbarItem: .matchedTransitionSource(id: GroupingSheet.zoomSourceID, in: namespace)
//
// `adjustPresentation` reads `\.columnLayout` and derives one binding per presentation
// (ADAPTIVE §4 S6): the stack gets the S6 sheet (large only, like Settings; was medium/large
// until 2026-11-22), zooming out of the button when that opened it, a cross-fade under Reduce
// Motion); the split gets a popover anchored to the view it is attached to, which is why it
// goes on the Adjust button, not on the screen. If the layout flips while Adjust is open, one closes and the other opens;
// the choices live in SettingsModel, so nothing is lost.
//
// To present it some other way, use `GroupingSheet(presentation:)` as the content: it carries
// its own NavigationStack, close button, detents and (for `.popover`) its ideal size.

/// The Adjust sheet or popover: a NavigationStack around `GroupingForm`, on which Pick Dates and
/// How Pickr. Finds Moments push (§3.3 S6, ADAPTIVE §4 S6). Plain system glass: no
/// `presentationBackground`.
struct GroupingSheet: View {
    /// How the content is presented, which decides its size and its close button's place.
    nonisolated enum Presentation: Hashable, Sendable {
        /// The S6 sheet when the Moments tab is stacked.
        case sheet
        /// Anchored to the Adjust button when the Moments tab is split.
        case popover
    }

    /// The `matchedTransitionSource` ID the Adjust toolbar item carries, so the sheet zooms out
    /// of it.
    static let zoomSourceID = "adjust"

    let presentation: Presentation

    /// Always large, like Settings (owner feedback 2026-11-22): opening at medium and jumping to
    /// large for Pick Dates or the help page made the sheet bounce.
    @State private var detent: PresentationDetent = .large
    @Environment(\.dismiss) private var dismiss

    init(presentation: Presentation = .sheet) {
        self.presentation = presentation
    }

    var body: some View {
        NavigationStack {
            GroupingForm(detent: $detent)
                .toolbar {
                    ToolbarItem(placement: presentation == .popover ? ToolbarItemPlacement.topBarTrailing : .cancellationAction) {
                        Button(role: .close) { dismiss() }
                    }
                }
        }
        // A popover sizes itself from its content's ideal size.
        .frame(
            idealWidth: presentation == .popover ? Self.popoverSize.width : nil,
            idealHeight: presentation == .popover ? Self.popoverSize.height : nil
        )
        // Detents and background interaction apply to the sheet, and to the popover once a
        // narrowing window turns it into one.
        .presentationDetents([.large], selection: $detent)
        .presentationSizing(.form)
        .presentationCompactAdaptation(presentation == .popover ? .sheet : .automatic)
    }

    private static let popoverSize = CGSize(width: 400, height: 560)
}

extension View {
    /// Presents Adjust while `router.sheet == .grouping`: the sheet when the Moments tab is
    /// stacked, a popover anchored to this view when it is split. Attach it to the Adjust
    /// toolbar button, whose `ToolbarItem` carries
    /// `.matchedTransitionSource(id: GroupingSheet.zoomSourceID, in: zoomNamespace)`. `zooms`:
    /// the sheet grows out of that button; pass `false` when Adjust was opened from elsewhere
    /// (the list's footer, "All clean"), so it slides up instead of growing out of a button the
    /// person didn't touch.
    func adjustPresentation(zoomNamespace: Namespace.ID, zooms: Bool = true) -> some View {
        modifier(AdjustPresentation(zoomNamespace: zoomNamespace, zooms: zooms))
    }
}

private struct AdjustPresentation: ViewModifier {
    let zoomNamespace: Namespace.ID
    let zooms: Bool

    @Environment(Router.self) private var router
    @Environment(\.columnLayout) private var layout

    func body(content: Content) -> some View {
        @Bindable var router = router
        content
            .sheet(isPresented: $router[showsAdjustAs: .stack, layout: layout]) {
                GroupingSheet(presentation: .sheet)
                    .zoomTransition(sourceID: GroupingSheet.zoomSourceID, in: zoomNamespace, isEnabled: zooms)
            }
            .popover(isPresented: $router[showsAdjustAs: .split, layout: layout]) {
                GroupingSheet(presentation: .popover)
            }
    }
}

extension Router {
    /// Whether Adjust shows in the presentation that belongs to `presentation`'s layout. Only
    /// the presentation that matches the current layout can close Adjust, so the one SwiftUI
    /// dismisses during a stack ↔ split flip never clears `sheet` under the other.
    fileprivate subscript(showsAdjustAs presentation: ColumnLayout, layout layout: ColumnLayout) -> Bool {
        get { sheet == .grouping && layout == presentation }
        set {
            if newValue {
                sheet = .grouping
            } else if sheet == .grouping, layout == presentation {
                sheet = nil
            }
        }
    }
}

#if DEBUG
#Preview("Adjust sheet") {
    let services = AdjustPreview.services()
    Color(.systemGroupedBackground)
        .ignoresSafeArea(edges: .vertical)
        .sheet(isPresented: .constant(true)) {
            GroupingSheet()
        }
        .adjustPreviewEnvironment(services)
}

#Preview("Adjust popover content") {
    let services = AdjustPreview.services { settings in
        settings.grouping.range = AdjustPreview.savedDates
    }
    GroupingSheet(presentation: .popover)
        .frame(width: 400, height: 560)
        .adjustPreviewEnvironment(services)
}

#Preview("Adjust, reading the library") {
    let services = AdjustPreview.services(library: .indexing)
    GroupingSheet()
        .adjustPreviewEnvironment(services)
}

#Preview("Adjust, no moments, dark") {
    let services = AdjustPreview.services(library: .empty)
    GroupingSheet()
        .adjustPreviewEnvironment(services)
        .preferredColorScheme(.dark)
}
#endif
