import PickrCore
import PickrModels
import SwiftUI

/// The tab bar's bottom accessory in the stack layout (§3.1, ADAPTIVE §3.1, COPY.md):
/// **Clean Up 7 Moments** over "Frees up to 32 MB", starting at the first moment in list
/// order. RootView enables it on both tabs while the Moments tab is stacked, at its root,
/// with moments listed (from Kept, `startReview` switches to Moments and Review appears without
/// a push animation); the split shows `ReviewStartView` instead.
///
/// Expanded, it shows both lines and drops the second, then shortens the title ("Clean Up
/// 7") when the width is tight. Inline (the tab bar minimized), it shows the title only.
/// The system gives it glass; the content is plain.
struct ReviewAccessory: View {
    @Environment(LibraryModel.self) private var library
    @Environment(Router.self) private var router
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        let list = library.moments
        let count = list.moments.count
        let freesUp = MomentsLabels.freesUpTo(list.savings)
        Button {
            start()
        } label: {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: "play.fill")
                    .imageScale(.medium)
                    .accessibilityHidden(true)
                titles(count: count, freesUp: freesUp)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.large)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The accessory's height is fixed by iOS: at large text sizes the title shrinks to fit
        // instead of clipping.
        .minimumScaleFactor(0.6)
        .disabled(list.moments.isEmpty)
        .accessibilityLabel(accessibilityLabel(count: count, freesUp: freesUp))
        .accessibilityHint(Text("Starts with the first moment.", comment: "VoiceOver hint on the Clean Up button."))
    }

    /// From Kept, Review takes the place of the tab at once, like a tab switch: zooming out of a
    /// card on a tab that was not on screen read as a second motion after the switch.
    private func start() {
        guard router.tab == .moments else {
            withTransaction(\.disablesAnimations, true) {
                router.startReview(at: nil)
            }
            return
        }
        router.startReview(at: nil)
    }

    @ViewBuilder
    private func titles(count: Int, freesUp: Text?) -> some View {
        if placement == .inline {
            ViewThatFits(in: .horizontal) {
                MomentsLabels.cleanUp(count).lineLimit(1)
                MomentsLabels.cleanUpShort(count).lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
        } else {
            ViewThatFits(in: .horizontal) {
                if let freesUp {
                    VStack(alignment: .leading, spacing: 0) {
                        MomentsLabels.cleanUp(count)
                            .font(.subheadline.weight(.semibold))
                        freesUp
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                }
                MomentsLabels.cleanUp(count)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                MomentsLabels.cleanUpShort(count)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
        }
    }

    /// "Clean Up 7 Moments, Frees up to 32 MB".
    private func accessibilityLabel(count: Int, freesUp: Text?) -> Text {
        guard let freesUp else { return MomentsLabels.cleanUp(count) }
        return Text("\(MomentsLabels.cleanUp(count)), \(freesUp)", comment: "VoiceOver: the Clean Up button. 1: Clean Up 7 Moments. 2: Frees up to 32 MB.")
    }
}

#if DEBUG
#Preview("Accessory") {
    MomentsPreviewHost(.moments) {
        TabView {
            Tab {
                NavigationStack {
                    Color.clear.navigationTitle("Moments")
                }
            } label: {
                Label("Moments", systemImage: "rectangle.stack")
            }
            Tab {
                Color.clear
            } label: {
                Label("Kept", systemImage: "checkmark.circle")
            }
        }
        .tabViewBottomAccessory {
            ReviewAccessory()
        }
    }
}
#endif
