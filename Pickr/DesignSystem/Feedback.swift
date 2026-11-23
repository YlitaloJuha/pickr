import PickrModels
import SwiftUI

// Haptics (§3.4). Every haptic in the app goes through `hapticFeedback`, which plays
// nothing when Settings > Haptics is off. UIKit feedback generators are never used.

extension SensoryFeedback {
    /// A photo was kept or unkept (tile tap, swipe up, the Keep toggle).
    nonisolated static var keepToggled: SensoryFeedback { .selection }
    /// A grouping picker or slider changed.
    nonisolated static var groupingChanged: SensoryFeedback { .selection }
    /// Photos were moved to Recently Deleted.
    nonisolated static var committed: SensoryFeedback { .success }
    /// An action failed. A cancelled system dialog is not a failure and plays nothing.
    nonisolated static var failed: SensoryFeedback { .error }
    /// A moment was kept aside.
    nonisolated static var keptAside: SensoryFeedback { .impact(weight: .light) }
    /// Photos were restored from Kept.
    nonisolated static var restored: SensoryFeedback { .impact(weight: .light) }
}

extension View {
    /// Plays `feedback` whenever `trigger` changes, unless haptics are off in Settings.
    func hapticFeedback<Trigger: Equatable>(_ feedback: SensoryFeedback, trigger: Trigger) -> some View {
        modifier(HapticFeedbackModifier(trigger: trigger) { _, _ in feedback })
    }

    /// Plays `feedback` when `trigger` changes and `condition` returns `true`, unless
    /// haptics are off in Settings.
    func hapticFeedback<Trigger: Equatable>(
        _ feedback: SensoryFeedback,
        trigger: Trigger,
        condition: @escaping (_ oldValue: Trigger, _ newValue: Trigger) -> Bool
    ) -> some View {
        modifier(HapticFeedbackModifier(trigger: trigger) { oldValue, newValue in
            condition(oldValue, newValue) ? feedback : nil
        })
    }

    /// Plays the feedback the closure returns when `trigger` changes (`nil` plays nothing),
    /// unless haptics are off in Settings. Use it when the feedback depends on the change,
    /// for example `.committed` versus `.failed` for a commit result.
    func hapticFeedback<Trigger: Equatable>(
        trigger: Trigger,
        _ feedback: @escaping (_ oldValue: Trigger, _ newValue: Trigger) -> SensoryFeedback?
    ) -> some View {
        modifier(HapticFeedbackModifier(trigger: trigger, feedback: feedback))
    }
}

/// The closure form of `sensoryFeedback`, which returns `nil` while haptics are off
/// (`SUI:2807`). Without a `SettingsModel` in the environment (previews) haptics play.
private struct HapticFeedbackModifier<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    let feedback: (_ oldValue: Trigger, _ newValue: Trigger) -> SensoryFeedback?

    @Environment(SettingsModel.self) private var settings: SettingsModel?

    func body(content: Content) -> some View {
        // Read here, not inside the closure, so the view tracks the setting.
        let isEnabled = settings?.hapticsEnabled ?? true
        content.sensoryFeedback(trigger: trigger) { oldValue, newValue in
            isEnabled ? feedback(oldValue, newValue) : nil
        }
    }
}
