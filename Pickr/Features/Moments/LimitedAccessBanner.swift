import SwiftUI

/// "Pickr. can see only some of your photos." with **Choose Photos** (§3.3 S3, COPY.md).
///
/// The first row of the Moments list (and above "All clean") while access is limited. A
/// solid card, never glass; it wraps to the column width. Choose Photos opens the system
/// limited-library picker; the × hides the banner for the rest of the app session.
struct LimitedAccessBanner: View {
    let onChoosePhotos: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            Image(systemName: "photo.on.rectangle")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                Text("Pickr. can see only some of your photos.", comment: "Banner shown while photo access is limited.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onChoosePhotos) {
                    Text("Choose Photos", comment: "Banner button that opens the system picker for the photos Pickr. can see.")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            // Borderless, so the row's other button keeps its own tap area inside a List.
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Dismiss", comment: "VoiceOver: hides the limited-access banner for now."))
            .padding(.top, -Theme.Spacing.medium)
            .padding(.trailing, -Theme.Spacing.small)
        }
        .cardSurface()
    }
}

#if DEBUG
#Preview("Limited banner", traits: .sizeThatFitsLayout) {
    LimitedAccessBanner(onChoosePhotos: {}, onDismiss: {})
        .padding()
        .background(Theme.Palette.screen)
}

#Preview("Limited banner, large text", traits: .sizeThatFitsLayout) {
    LimitedAccessBanner(onChoosePhotos: {}, onDismiss: {})
        .padding()
        .background(Theme.Palette.screen)
        .dynamicTypeSize(.accessibility3)
}
#endif
