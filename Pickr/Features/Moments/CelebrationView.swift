import PickrCore
import PickrModels
import PickrPersistence
import SwiftUI

/// The "All clean" state (§3.3 S3, COPY.md): no moments in the look-back period, the
/// **Just now** totals (this app session, when something was deleted) and the **All time**
/// totals, and an **Adjust** button.
///
/// Full width with a readable column (ADAPTIVE §5.1); it scrolls at large text sizes.
struct CelebrationView: View {
    let onAdjust: () -> Void

    @Environment(SettingsModel.self) private var settings

    var body: some View {
        let allTime = settings.stats
        let justNow = SessionTotals(settings.sessionStats)
        VStack(spacing: Theme.Spacing.large) {
            Image(systemName: "bubbles.and.sparkles")
                .font(.largeTitle)
                .imageScale(.large)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(spacing: Theme.Spacing.small) {
                Text("All clean", comment: "Moments tab with no moments left: title.")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                lookBackSentence
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            CelebrationTotals(justNow: justNow, allTime: allTime)
            Button(action: onAdjust) {
                Text("Adjust", comment: "Button that opens the Adjust sheet (how moments are found).")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .padding(Theme.Spacing.large)
        .readableWidth()
    }

    /// Names the look-back period, so an empty list never looks broken.
    private var lookBackSentence: Text {
        switch settings.grouping.range.effectivePreset {
        case .d7:
            Text("No moments in the last week.", comment: "All clean: Look back is Week.")
        case .d14:
            Text("No moments in the last 2 weeks.", comment: "All clean: Look back is 2 Weeks.")
        case .d30:
            Text("No moments in the last month.", comment: "All clean: Look back is Month.")
        case .all:
            Text("No moments in your library.", comment: "All clean: Look back is Everything.")
        case .custom:
            Text("No moments on the dates you picked.", comment: "All clean: Look back is a range of dates the user picked.")
        }
    }
}

/// What was done since the app launched (`SettingsModel.sessionStats`).
struct SessionTotals: Equatable {
    let moments: Int
    let photos: Int
    let bytes: Int64

    init(moments: Int, photos: Int, bytes: Int64) {
        self.moments = moments
        self.photos = photos
        self.bytes = bytes
    }

    init(_ session: LifetimeStats) {
        moments = session.momentsCleared
        photos = session.photosDeleted
        bytes = session.bytesFreed
    }
}

/// The solid totals card: **Just now** (only after a delete in this session) and **All time**.
struct CelebrationTotals: View {
    let justNow: SessionTotals?
    let allTime: LifetimeStats

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if let justNow, justNow.moments > 0 {
                TotalsGroup(title: Text("Just now", comment: "All clean: heading for what was done since the app opened.")) {
                    LabeledContent {
                        Text(justNow.moments, format: .number)
                    } label: {
                        Text("Moments done", comment: "All clean: moments finished since the app opened.")
                    }
                    LabeledContent {
                        Text(justNow.photos, format: .number)
                    } label: {
                        Text("Photos deleted", comment: "All clean: photos moved to Recently Deleted.")
                    }
                    if justNow.bytes > 0 {
                        LabeledContent {
                            Text(PickrFormat.bytes(justNow.bytes))
                        } label: {
                            Text("Space freed up", comment: "All clean: storage freed by the deleted photos.")
                        }
                    }
                }
                Divider()
            }
            TotalsGroup(title: Text("All time", comment: "All clean: heading for the lifetime totals.")) {
                LabeledContent {
                    Text(allTime.photosDeleted, format: .number)
                } label: {
                    Text("Photos deleted", comment: "All clean: photos moved to Recently Deleted.")
                }
                LabeledContent {
                    Text(PickrFormat.bytes(allTime.bytesFreed))
                } label: {
                    Text("Space freed up", comment: "All clean: storage freed by the deleted photos.")
                }
            }
        }
        .font(.subheadline)
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

private struct TotalsGroup<Rows: View>: View {
    let title: Text
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            title
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            rows
        }
    }
}

#if DEBUG
#Preview("All clean") {
    MomentsPreviewHost(.allClean)
}

#Preview("All clean, just now", traits: .sizeThatFitsLayout) {
    CelebrationTotals(
        justNow: SessionTotals(moments: 3, photos: 11, bytes: 48_000_000),
        allTime: LifetimeStats(photosDeleted: 1_222, bytesFreed: 2_448_000_000, momentsCleared: 303, firstUse: .now)
    )
    .padding()
    .momentsPreviewEnvironment(.allClean)
}

#Preview("All clean, dark, large text") {
    MomentsPreviewHost(.allClean)
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}
#endif
