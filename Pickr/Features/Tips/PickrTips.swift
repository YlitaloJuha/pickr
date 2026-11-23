import SwiftUI
import TipKit

// Final (WP0). TipKit replaces the v1 hint banners (§2.2 C14). TipKit keeps its state in
// its own on-device datastore; CloudKit sync is never configured.

/// Taught on the first moment card: the Moments list's swipe actions.
nonisolated struct SwipeMomentTip: Tip {
    var title: Text {
        Text("Swipe to decide", comment: "Tip title on the first moment in the Moments list.")
    }

    var message: Text? {
        Text("Swipe left to delete a whole moment, or right to keep all of it.", comment: "Tip on the first moment in the Moments list: its swipe actions.")
    }

    var image: Image? {
        Image(systemName: "hand.draw")
    }
}

/// Taught on the first tile in Review's grid.
nonisolated struct TapToKeepTip: Tip {
    var title: Text {
        Text("Tap to keep", comment: "Tip title on the first photo in Review.")
    }

    var message: Text? {
        Text("Tap the photos you want to keep. The rest go to Recently Deleted.", comment: "Tip on the first photo in Review. Recently Deleted is the album name in the Photos app.")
    }

    var image: Image? {
        Image(systemName: "hand.tap")
    }
}

/// Taught in Review's single-photo mode.
nonisolated struct SwipeUpKeepTip: Tip {
    var title: Text {
        Text("Swipe up to keep", comment: "Tip title in Review, One by One.")
    }

    var message: Text? {
        Text("Swipe up on a photo to keep it.", comment: "Tip in Review, One by One: the swipe-up gesture.")
    }

    var image: Image? {
        Image(systemName: "hand.point.up.left")
    }
}

/// Configuration and bulk operations for Pickr.'s tips.
enum PickrTips {
    /// Set once the v1 hint state has been carried over, so "Show tips again" sticks.
    /// Stored in TipKit's datastore, not in UserDefaults.
    @Parameter static var legacyStateApplied: Bool = false

    /// Call once at launch, before any tip view appears.
    static func configure() {
        #if DEBUG
        if DemoMode.isActive {
            DemoServices.configureTips()
            return
        }
        #endif
        // Fails only if called twice; the first configuration stays in effect.
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault),
        ])
    }

    /// Carries the v1 hint-banner state over to TipKit, once.
    ///
    /// - Parameters:
    ///   - seen: `LegacyTips.seen(in:)`, read from the v1 hint counters.
    ///   - isUpgrade: `MigrationV1.isUpgrade(_:)`, evaluated before launch writes anything.
    ///     Upgraders already know the Moments swipe gestures from v1.
    static func applyLegacyState(_ seen: (tapToKeep: Bool, swipeUp: Bool), isUpgrade: Bool) {
        guard !legacyStateApplied else { return }
        if seen.tapToKeep {
            TapToKeepTip().invalidate(reason: .actionPerformed)
        }
        if seen.swipeUp {
            SwipeUpKeepTip().invalidate(reason: .actionPerformed)
        }
        if isUpgrade {
            SwipeMomentTip().invalidate(reason: .actionPerformed)
        }
        legacyStateApplied = true
    }

    /// Settings > Help > Show Tips Again.
    static func showAgain() async {
        await SwipeMomentTip().resetEligibility()
        await TapToKeepTip().resetEligibility()
        await SwipeUpKeepTip().resetEligibility()
    }
}
