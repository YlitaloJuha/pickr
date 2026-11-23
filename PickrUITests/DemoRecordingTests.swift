import XCTest

/// The README demos, recorded by `scripts/demo-gifs.sh` (docs/RELEASING.md, "README demos").
///
/// Every test is skipped unless the test runner's environment has `PICKR_DEMO=1` (the script
/// passes `TEST_RUNNER_PICKR_DEMO=1` to xcodebuild), so ordinary UI test runs and CI never
/// run them. Each one launches the app in demo mode (`-PickrDemo YES`, Debug builds only):
/// the 40 synthetic test photos in memory, no PhotoKit, onboarding done, Look back
/// Everything. A relaunch starts with all 40 photos again, so every test stands alone.
///
/// Safety: a test checks for the app's `pickr.demo-mode` accessibility marker before its
/// first tap and stops, closing the app, if demo mode isn't on. The tests never touch system
/// UI (policy check 23): demo deletes have no iOS dialog.
///
/// Pacing is a person's: about a second between actions, a longer hold on the frames that
/// matter. Loading waits on elements, never on time. `mark` logs `PICKR-DEMO-MARK` lines with
/// the device's clock; the script cuts each recording from `start` to `end` and takes the
/// README screenshots at the `still:<name>` marks.
///
/// The target's default isolation is nonisolated (XCTestCase's initializers are), so methods
/// that drive the UI are @MainActor.
final class DemoRecordingTests: XCTestCase {
    private struct DemoModeInactive: Error {}

    /// The demo being recorded, for the marks.
    private var demo = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PICKR_DEMO"] == "1",
            "README demo recordings run only from scripts/demo-gifs.sh (PICKR_DEMO=1)"
        )
    }

    // MARK: - Demos

    /// The list scrolls a little over its photo strip, a moment opens in All, two keepers,
    /// Delete, and Review moves on to the next moment.
    @MainActor
    func testHero() throws {
        let app = try launchDemo("hero")
        // The sunset moment (5 photos), like the README banner; it is further down the list.
        XCTAssertTrue(app.buttons["moments.card"].firstMatch.waitForExistence(timeout: 20), "The demo moments should list")

        mark("start")
        hold(1.0)
        mark("still:moments")
        hold(1.0)
        // Scroll down the strip of blurred photos to the sunset moment.
        for _ in 0..<5 where !momentCard(app, photos: 5).isHittable {
            scrollList(app, by: 0.3)
            hold(0.4)
        }
        hold(0.8)

        tap(momentCard(app, photos: 5))
        XCTAssertTrue(app.staticTexts["Tap the photos to keep"].waitForExistence(timeout: 10))
        hold(1.2)
        keep(photoTile(app, position: 2))
        beat()
        keep(photoTile(app, position: 4))
        beat(1.0)

        let delete = deleteButton(app)
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertTrue(delete.label.hasPrefix("Delete 3 photos"), "Unexpected Delete button: \(delete.label)")
        tap(delete)
        XCTAssertTrue(toast(app, startingWith: "Moved 3 photos").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Tap the photos to keep"].waitForExistence(timeout: 10), "Review moves on")
        hold(2.0)
        mark("end")
    }

    /// Review: keepers in All, then One by One, a few photos sideways, and Keep.
    @MainActor
    func testReview() throws {
        let app = try launchDemo("review")
        let card = momentCard(app, photos: 10)
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        scrollIntoView(card, app: app)
        card.tap()
        XCTAssertTrue(app.staticTexts["Tap the photos to keep"].waitForExistence(timeout: 10))
        XCTAssertTrue(photoTile(app, position: 1).waitForExistence(timeout: 10))

        mark("start")
        hold(1.2)
        keep(photoTile(app, position: 1))
        beat()
        keep(photoTile(app, position: 3))
        beat()
        keep(photoTile(app, position: 8))
        hold(1.0)
        mark("still:review-grid")
        hold(1.0)

        tap(control(app, labeled: "One by One"))
        let pager = app.descendants(matching: .any).matching(identifier: "PhotoPager").firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        hold(1.2)
        for _ in 0..<3 {
            pager.swipeLeft(velocity: .default)
            beat(1.0)
        }
        let keepToggle = app.buttons["Keep"]
        XCTAssertTrue(keepToggle.waitForExistence(timeout: 5))
        // Keep lands on a photo that isn't kept yet.
        for _ in 0..<4 where keepToggle.isSelected {
            pager.swipeLeft(velocity: .default)
            beat(1.0)
        }
        tap(keepToggle)
        XCTAssertTrue(keepToggle.waitForSelected(true, timeout: 5), "Keep marks the photo")
        hold(1.0)
        mark("still:review-single")
        hold(1.2)
        mark("end")
    }

    /// The Moments list's swipes: Keep All to the right (with the undo toast), Delete All to
    /// the left.
    @MainActor
    func testSwipe() throws {
        let app = try launchDemo("swipe")
        let cards = app.buttons.matching(identifier: "moments.card")
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 20))

        mark("start")
        hold(1.2)
        let first = cards.element(boundBy: 0)
        let firstLabel = first.label
        swipeAction(on: first, toward: .right, button: "Keep All", app: app)
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 5), "Keep All shows an undo toast")
        XCTAssertTrue(toast(app, startingWith: "Moment kept").exists)
        XCTAssertTrue(waitForFirstCard(in: cards, toDifferFrom: firstLabel), "The kept moment left the list")
        hold(1.8)

        swipeAction(on: cards.element(boundBy: 0), toward: .left, button: "Delete All", app: app)
        XCTAssertTrue(toast(app, startingWith: "Moved").waitForExistence(timeout: 10))
        hold(2.0)
        mark("end")
    }

    /// Adjust: Photos taken within 1 min → 10 sec → 3 min, the list regrouping behind the
    /// sheet and the count following, then Close.
    @MainActor
    func testAdjust() throws {
        let app = try launchDemo("adjust")
        XCTAssertTrue(momentCard(app, photos: 8).waitForExistence(timeout: 20))

        mark("start")
        hold(1.2)
        tap(adjustButton(app))
        XCTAssertTrue(summary(app, startingWith: "7 moments · 40 photos").waitForExistence(timeout: 5))
        hold(1.4)
        chooseWindow("10 sec", app: app)
        XCTAssertTrue(summary(app, startingWith: "10 moments · 40 photos").waitForExistence(timeout: 5))
        hold(1.6)
        chooseWindow("3 min", app: app)
        XCTAssertTrue(summary(app, startingWith: "3 moments · 40 photos").waitForExistence(timeout: 5))
        hold(1.0)
        mark("still:adjust")
        hold(1.0)
        closeAdjust(app)
        XCTAssertTrue(summary(app, startingWith: "3 moments · 40 photos").waitForNonExistence(timeout: 5), "Adjust closed")
        hold(1.6)
        mark("end")
    }

    /// The Kept tab: Moments you kept and Photos you picked, a kept moment, and Show Moment
    /// Again with its undo toast. Before the cut: Keep All on one moment and one keeper in
    /// another.
    @MainActor
    func testKept() throws {
        let app = try launchDemo("kept")
        let cards = app.buttons.matching(identifier: "moments.card")
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 20))

        // Set-up, cut from the GIF.
        let firstLabel = cards.element(boundBy: 0).label
        swipeAction(on: cards.element(boundBy: 0), toward: .right, button: "Keep All", app: app, paced: false)
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFirstCard(in: cards, toDifferFrom: firstLabel))
        cards.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Tap the photos to keep"].waitForExistence(timeout: 10))
        let firstPhoto = photoTile(app, position: 1)
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10))
        firstPhoto.tap()
        XCTAssertTrue(firstPhoto.waitForSelected(true, timeout: 5))
        tap(deleteButton(app))
        XCTAssertTrue(toast(app, startingWith: "Moved").waitForExistence(timeout: 10))
        goBack(app)
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10), "Back on the Moments list")
        XCTAssertTrue(app.buttons["Undo"].waitForNonExistence(timeout: 15), "The toasts have gone")
        XCTAssertTrue(toast(app, startingWith: "Moved").waitForNonExistence(timeout: 15))

        mark("start")
        hold(1.2)
        tap(tabButton(app, "Kept"))
        let keptCard = app.descendants(matching: .any).matching(identifier: "kept.card").firstMatch
        XCTAssertTrue(app.staticTexts["Moments you kept"].waitForExistence(timeout: 10))
        XCTAssertTrue(keptCard.waitForExistence(timeout: 10))
        hold(1.2)
        let picked = control(app, labeled: "Photos you picked", prefix: true)
        tap(picked)
        hold(1.0)
        mark("still:kept")
        hold(1.0)
        tap(keptCard)
        let showAgain = app.buttons["Show Moment Again"]
        XCTAssertTrue(showAgain.waitForExistence(timeout: 10))
        hold(1.6)
        tap(showAgain)
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 5), "Show Moment Again shows an undo toast")
        hold(2.0)
        mark("end")
    }

    // MARK: - Launch and marks

    /// Launches the app in demo mode and refuses to go on without the demo-mode marker: if it
    /// is missing, the app is closed before anything is touched and the test fails.
    @MainActor
    private func launchDemo(_ name: String) throws -> XCUIApplication {
        demo = name
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-PickrDemo", "YES", "-PickrDemoAppearance", appearance]
        app.launch()
        let marker = app.descendants(matching: .any).matching(identifier: "pickr.demo-mode").firstMatch
        guard marker.waitForExistence(timeout: 15) else {
            app.terminate()
            XCTFail("Demo mode is not on (no pickr.demo-mode marker): is this a Debug build? Stopped before touching anything.")
            throw DemoModeInactive()
        }
        return app
    }

    /// `PICKR_DEMO_APPEARANCE` from the script: `light` or `dark`.
    private var appearance: String {
        ProcessInfo.processInfo.environment["PICKR_DEMO_APPEARANCE"] == "light" ? "light" : "dark"
    }

    /// Logs `PICKR-DEMO-MARK <appearance> <demo> <event> <seconds since 1970>`, to the console
    /// and as an activity in the result bundle.
    @MainActor
    private func mark(_ event: String) {
        let line = String(
            format: "PICKR-DEMO-MARK %@ %@ %@ %.3f",
            appearance, demo, event, Date().timeIntervalSince1970
        )
        print(line)
        XCTContext.runActivity(named: line) { _ in }
    }

    // MARK: - Pacing

    /// The pause between two actions.
    private func beat(_ seconds: TimeInterval = 0.8) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// A hold on a frame that matters.
    private func hold(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: - Finding things

    /// The Moments card with this many photos (its label reads "…, 8 photos, …").
    @MainActor
    private func momentCard(_ app: XCUIApplication, photos: Int) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "moments.card", ", \(photos) photos"))
            .firstMatch
    }

    /// The Review tile whose VoiceOver label starts "Photo <position> of".
    @MainActor
    private func photoTile(_ app: XCUIApplication, position: Int) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Photo \(position) of"))
            .firstMatch
    }

    /// Review's main button, "Delete 6 Photos" (VoiceOver: "Delete 6 photos, frees up …").
    @MainActor
    private func deleteButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Delete ")).firstMatch
    }

    @MainActor
    private func toast(_ app: XCUIApplication, startingWith text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    /// The Adjust sheet's live count, "10 moments · 40 photos · … to free up".
    @MainActor
    private func summary(_ app: XCUIApplication, startingWith text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    /// The first hittable element of any type with this label (pickers, segments and section
    /// headers aren't always buttons).
    @MainActor
    private func control(_ app: XCUIApplication, labeled label: String, prefix: Bool = false) -> XCUIElement {
        let predicate = prefix
            ? NSPredicate(format: "label BEGINSWITH %@", label)
            : NSPredicate(format: "label == %@", label)
        let button = app.buttons.matching(predicate).firstMatch
        if button.waitForExistence(timeout: 5) { return button }
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    @MainActor
    private func adjustButton(_ app: XCUIApplication) -> XCUIElement {
        let inBar = app.navigationBars["Moments"].buttons["Adjust"]
        return inBar.waitForExistence(timeout: 5) ? inBar : app.buttons["Adjust"].firstMatch
    }

    @MainActor
    private func tabButton(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let tab = app.tabBars.buttons[label]
        return tab.waitForExistence(timeout: 5) ? tab : app.buttons[label].firstMatch
    }

    // MARK: - Actions

    @MainActor
    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Not found: \(element)", file: file, line: line)
        element.tap()
    }

    /// Taps a Review tile to keep it; on a first run a tip may take the first tap.
    @MainActor
    private func keep(_ tile: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        tap(tile, file: file, line: line)
        if !tile.waitForSelected(true, timeout: 2) { tile.tap() }
        XCTAssertTrue(tile.waitForSelected(true, timeout: 3), "A kept photo has the selected trait", file: file, line: line)
    }

    /// Drags the list up by `fraction` of the window's height, slowly, and holds before
    /// letting go so it doesn't fling.
    @MainActor
    private func scrollList(_ app: XCUIApplication, by fraction: CGFloat) {
        let window = app.windows.firstMatch
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7 - fraction))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(320), thenHoldForDuration: 0.3)
    }

    /// Scrolls the list until `element` can be tapped (before the cut only).
    @MainActor
    private func scrollIntoView(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable {
            scrollList(app, by: 0.25)
        }
        XCTAssertTrue(element.isHittable, "Could not scroll to \(element)")
    }

    private enum SwipeDirection { case left, right }

    /// Reveals a row's swipe actions with a slow, partial drag, then taps the action, as a
    /// person would. Falls back to a system swipe if the drag revealed nothing.
    @MainActor
    private func swipeAction(
        on row: XCUIElement,
        toward direction: SwipeDirection,
        button label: String,
        app: XCUIApplication,
        paced: Bool = true
    ) {
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let (start, end): (CGFloat, CGFloat) = direction == .right ? (0.12, 0.55) : (0.88, 0.45)
        let from = row.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.5))
        let to = row.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(paced ? 420 : 900), thenHoldForDuration: 0.15)
        let action = app.buttons[label]
        if !action.waitForExistence(timeout: 2) || !action.isHittable {
            if direction == .right { row.swipeRight() } else { row.swipeLeft() }
        }
        if paced { beat(0.7) }
        if action.waitForExistence(timeout: 3), action.isHittable {
            action.tap()
        }
    }

    /// Back from a pushed screen: the navigation bar's back button, or the edge swipe.
    @MainActor
    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons["BackButton"]
        if back.waitForExistence(timeout: 3) {
            back.tap()
            return
        }
        let leading = app.navigationBars.firstMatch.buttons.element(boundBy: 0)
        if leading.exists, leading.isHittable, leading.frame.minX < 80 {
            leading.tap()
            return
        }
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
    }

    /// The Adjust sheet's close button (the system's xmark), or a swipe down.
    @MainActor
    private func closeAdjust(_ app: XCUIApplication) {
        let close = app.buttons["Close"]
        if close.waitForExistence(timeout: 3), close.isHittable {
            close.tap()
            return
        }
        let bar = app.navigationBars["Adjust"]
        let button = bar.buttons.firstMatch
        if button.waitForExistence(timeout: 2) {
            button.tap()
        } else {
            bar.swipeDown(velocity: .fast)
        }
    }

    /// Waits until the list's first card is another moment (a kept or deleted one has left).
    @MainActor
    private func waitForFirstCard(in cards: XCUIElementQuery, toDifferFrom label: String) -> Bool {
        let predicate = NSPredicate(format: "label != %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: cards.element(boundBy: 0))
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }

    /// Photos taken within: a segment, or the menu the picker becomes when the segments don't
    /// fit.
    @MainActor
    private func chooseWindow(_ label: String, app: XCUIApplication) {
        let segment = app.buttons[label]
        if segment.waitForExistence(timeout: 3), segment.isHittable {
            segment.tap()
            return
        }
        tap(control(app, labeled: "Photos taken within", prefix: true))
        tap(app.buttons[label])
    }
}

private extension XCUIElement {
    /// Waits until the element's selected state is `selected` (a kept photo has the trait).
    @MainActor
    func waitForSelected(_ selected: Bool, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "selected == %@", NSNumber(value: selected))
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
