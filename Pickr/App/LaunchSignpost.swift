import os

/// The launch interval for Instruments (blueprint §6.4): from `PickrApp.init` until the
/// window first shows a settled state (the Moments list, All clean, onboarding or an access
/// or error state). Local only, like every other signpost: no telemetry.
enum LaunchSignpost {
    private static let signposter = OSSignposter(subsystem: "com.juha.Culler", category: "App")
    private static var state: OSSignpostIntervalState?
    private static var hasEnded = false

    static func begin() {
        guard state == nil, !hasEnded else { return }
        state = signposter.beginInterval("Launch to first frame")
    }

    /// Ends the interval once; later calls do nothing.
    static func end() {
        guard let state else { return }
        signposter.endInterval("Launch to first frame", state)
        self.state = nil
        hasEnded = true
    }
}
