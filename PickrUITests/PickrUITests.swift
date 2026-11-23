import XCTest

/// End-to-end tests (blueprint §4.8, ADAPTIVE §12.3) on a simulator that has the 40 photos in
/// `test-photos/` and Photos access granted before the run, as CI's `sim` job does:
///
///     xcrun simctl addmedia booted test-photos/*.jpg
///     xcrun simctl privacy booted grant photos com.juha.Culler
///
/// The test photos were taken on 12 April 2026, so every launch looks back over the whole
/// library (`-settings.scanRangePreset all`, read from the arguments domain; nothing is
/// written). With the default 1-minute window they make 7 moments.
///
/// The tests find controls by the words people see (audit/COPY.md), so a copy change shows up
/// here too.
///
/// They never touch system UI (policy check 23): no SpringBoard, no interruption monitor, so
/// nothing can ever confirm an iOS "Delete photos?" dialog, even on a device. The live test
/// stops at the Delete button; the delete itself runs in demo mode (`-PickrDemo YES`, Debug
/// builds), where the photos are the synthetic ones in memory and there is no dialog.
///
/// The target's default isolation is nonisolated (XCTestCase's initializers are), so methods
/// that drive the UI are @MainActor.
final class PickrUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Tests

    /// First run against the live library: onboarding → access → 7 moments → Review → keep
    /// one photo → the Delete button offers the rest. It stops there: confirming would need
    /// the iOS dialog, which these tests never touch.
    @MainActor
    func testFirstRunAndCoreLoop() throws {
        let app = launchApp()
        passOnboardingIfNeeded(app)
        dismissWhatsNewIfNeeded(app)

        let cleanUp = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Clean Up 7 Moments")).firstMatch
        XCTAssertTrue(cleanUp.waitForExistence(timeout: 30), "The test photos should make 7 moments")
        // A sheet that is still closing (What's New) can swallow the first tap.
        let reviewHint = app.staticTexts["Tap the photos to keep"]
        for _ in 0..<3 where !reviewHint.exists {
            if cleanUp.isHittable { cleanUp.tap() }
            _ = reviewHint.waitForExistence(timeout: 4)
        }

        // Review opens in All with nothing kept.
        XCTAssertTrue(reviewHint.waitForExistence(timeout: 10))
        let firstPhoto = photoTile(app, position: 1)
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10))
        firstPhoto.tap()
        // On a first run the "Tap to keep" tip may take the first tap to close itself.
        if !firstPhoto.isSelected { firstPhoto.tap() }
        XCTAssertTrue(firstPhoto.isSelected, "A kept photo has the selected trait")

        let delete = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Delete")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertTrue(delete.isEnabled, "Delete offers the photos that aren't kept")
    }

    /// The core loop in demo mode, with no PhotoKit and no dialog: Review → keep one photo →
    /// Delete → the toast, and Review moves on.
    @MainActor
    func testCoreLoopInDemoMode() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-PickrDemo", "YES"]
        app.launch()
        let marker = app.descendants(matching: .any).matching(identifier: "pickr.demo-mode").firstMatch
        guard marker.waitForExistence(timeout: 15) else {
            app.terminate()
            XCTFail("Demo mode is not on (no pickr.demo-mode marker); stopped before touching anything")
            return
        }

        let cleanUp = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Clean Up 7 Moments")).firstMatch
        XCTAssertTrue(cleanUp.waitForExistence(timeout: 30), "The demo photos make 7 moments")
        cleanUp.tap()

        XCTAssertTrue(app.staticTexts["Tap the photos to keep"].waitForExistence(timeout: 10))
        let firstPhoto = photoTile(app, position: 1)
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10))
        firstPhoto.tap()
        XCTAssertTrue(firstPhoto.isSelected, "A kept photo has the selected trait")

        let delete = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Delete")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()

        let toast = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Moved")).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 15), "A toast confirms the photos went to Recently Deleted")
        XCTAssertTrue(app.staticTexts["Tap the photos to keep"].waitForExistence(timeout: 10), "Review moves on")
    }

    /// Side by side (ADAPTIVE §12.3): open Review from the sidebar, keep two photos with Space,
    /// and check that the sidebar's highlight follows Skip. Runs only in a window at least
    /// 740 pt wide in a regular size class (an iPad, or a wide resizable window).
    @MainActor
    func testSplitSidebarFollowsReview() throws {
        let app = launchApp()
        passOnboardingIfNeeded(app)
        dismissWhatsNewIfNeeded(app)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        try XCTSkipUnless(window.frame.width >= 740, "Needs a window wide enough for the split (740 pt)")

        // The empty detail column offers the same Clean Up button as the iPhone accessory.
        let start = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Clean Up")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        start.tap()

        let selectedRow = app.cells.matching(NSPredicate(format: "selected == true")).firstMatch
        XCTAssertTrue(selectedRow.waitForExistence(timeout: 10), "The sidebar highlights the moment under review")
        // The row itself has no label; its moment card does.
        let firstMoment = selectedRow.buttons["moments.card"].firstMatch.label

        // Space keeps the photo under the focus ring; an arrow key shows the ring.
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        let kept = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND selected == true", "Photo "))
        XCTAssertEqual(kept.count, 2, "Space kept two photos")

        app.buttons["Skip"].tap()
        let next = app.cells.matching(NSPredicate(format: "selected == true")).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertFalse(firstMoment.isEmpty)
        XCTAssertNotEqual(next.buttons["moments.card"].firstMatch.label, firstMoment, "The highlight moved to the next moment")
    }

    /// The system accessibility audit on the Moments list.
    @MainActor
    func testMomentsAccessibilityAudit() throws {
        let app = launchApp()
        passOnboardingIfNeeded(app)
        dismissWhatsNewIfNeeded(app)
        XCTAssertTrue(app.navigationBars["Moments"].waitForExistence(timeout: 30))
        try app.performAccessibilityAudit(for: [
            .dynamicType, .elementDetection, .hitRegion, .sufficientElementDescription, .textClipped, .trait,
        ]) { issue in
            // The tab bar's bottom accessory has a height iOS fixes, so its title can't grow
            // with every Dynamic Type size (as in Apple's own apps). The same action is on
            // every card and in the Clean Up menu, so this one finding is accepted.
            if issue.auditType == .dynamicType, let label = issue.element?.label, label.hasPrefix("Clean Up") || label.hasPrefix("Frees up") {
                return true
            }
            // A text-size finding with no element is system chrome (the iPad's top tab bar
            // labels), which the app can't make scale; every view of the app is SwiftUI and
            // reports its element.
            if issue.auditType == .dynamicType, issue.element == nil {
                return true
            }
            // Name the element, so a failure says what to fix.
            print("AUDIT ISSUE: \(issue.compactDescription) | \(issue.detailedDescription) | \(issue.element?.debugDescription.prefix(300) ?? "no element")")
            return false
        }
    }

    // MARK: - Steps

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-settings.scanRangePreset", "all", "-PickrHideTips"]
        app.launch()
        return app
    }

    /// Welcome → Continue → Allow Photo Access. Access must be granted before the run
    /// (`simctl privacy … grant photos`), so iOS shows no prompt; the tests never answer one.
    @MainActor
    private func passOnboardingIfNeeded(_ app: XCUIApplication) {
        guard app.staticTexts["Welcome to Pickr."].waitForExistence(timeout: 5) else { return }
        app.buttons["Continue"].tap()
        let allow = app.buttons["Allow Photo Access"]
        if allow.waitForExistence(timeout: 5) {
            allow.tap()
        }
    }

    /// What's New shows once after an upgrade from 1.0; a fresh install never sees it.
    @MainActor
    private func dismissWhatsNewIfNeeded(_ app: XCUIApplication) {
        if app.staticTexts["What's New in Pickr."].waitForExistence(timeout: 3) {
            app.buttons["Continue"].tap()
        }
        // Tips are hidden in UI tests (-PickrHideTips): XCUITest can't close TipKit popovers reliably.
    }

    /// The Review tile whose VoiceOver label starts "Photo <position> of".
    @MainActor
    private func photoTile(_ app: XCUIApplication, position: Int) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Photo \(position) of"))
            .firstMatch
    }
}
