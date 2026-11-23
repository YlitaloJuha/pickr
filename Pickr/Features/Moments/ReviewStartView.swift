import PickrCore
import PickrModels
import SwiftUI

/// The split's detail when no moment is under review (ADAPTIVE S3, D4): the count line
/// "7 moments · 32 MB to free up", one inline **Clean Up 7 Moments** button that starts at
/// the first moment, and the keyboard hint. It replaces the bottom accessory there; nothing
/// is pre-selected.
///
/// The column paints the list's ambient background (applied by `MomentsColumns`), so this
/// view stays clear. The button is inline content, so it is `.borderedProminent`, not glass.
struct ReviewStartView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(Router.self) private var router

    var body: some View {
        let list = library.moments
        CenteredScrollView {
            VStack(spacing: Theme.Spacing.large) {
                Image(systemName: "rectangle.stack")
                    .font(.largeTitle)
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(spacing: Theme.Spacing.small) {
                    MomentsLabels.summary(list)
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        "Choose a moment in the list, or start at the top.",
                        comment: "Start view beside the Moments list when no moment is open."
                    )
                    .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                Button {
                    router.startReview(at: nil)
                } label: {
                    Label {
                        MomentsLabels.cleanUp(list.moments.count)
                    } icon: {
                        Image(systemName: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(list.moments.isEmpty)
                Text("Space keeps · ⌘⌫ deletes · ⌘↓ skips", comment: "Start view: keyboard shortcuts for going through moments.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel(Text(
                        "With a keyboard, Space keeps a photo, Command Delete deletes, Command Down Arrow skips.",
                        comment: "VoiceOver reading of the start view's keyboard shortcuts."
                    ))
            }
            .padding(Theme.Spacing.large)
            .readableWidth()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
#Preview("Start view", traits: .fixedLayout(width: 760, height: 820)) {
    MomentsPreviewHost(.moments) {
        NavigationStack {
            ReviewStartView()
                .modifier(MomentsListAmbient(focusedMoment: .constant(nil), isEnabled: true))
        }
    }
}

#Preview("Start view, large text", traits: .fixedLayout(width: 760, height: 820)) {
    MomentsPreviewHost(.moments) {
        NavigationStack {
            ReviewStartView()
                .modifier(MomentsListAmbient(focusedMoment: .constant(nil), isEnabled: true))
        }
    }
    .dynamicTypeSize(.accessibility3)
}
#endif
