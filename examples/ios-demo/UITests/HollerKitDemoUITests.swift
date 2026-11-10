import XCTest

final class HollerKitDemoUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testQuestOverlayReceivesTapsAndPassesThroughOutsideBar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--skip-auto-report"]
        app.launch()

        // 1. Open the Quest Board and start the checkout quest
        let questsButton = app.buttons["DemoQuestsButton"]
        XCTAssertTrue(questsButton.waitForExistence(timeout: 5))
        questsButton.tap()

        let startQuestButton = app.buttons["HollerKitStartQuestButton_checkout-promo-math"]
        if !startQuestButton.waitForExistence(timeout: 5) {
            XCTFail("Start quest button did not appear. Hierarchy:\n\(app.debugDescription)")
            return
        }
        startQuestButton.tap()

        let markButton = app.buttons["HollerKitQuestMarkButton"]
        let doneButton = app.buttons["HollerKitQuestDoneButton"]
        let expandButton = app.buttons["HollerKitQuestExpandButton"]
        if !markButton.waitForExistence(timeout: 5) {
            XCTFail("Mark button did not appear. Hierarchy:\n\(app.debugDescription)")
            return
        }
        XCTAssertTrue(doneButton.exists)
        XCTAssertTrue(expandButton.exists)
        XCTAssertEqual(markButton.value as? String, "0")

        // 2. Tap a host-app button outside the bar and assert the host app received it
        let payButton = app.buttons["DemoPayButton"]
        XCTAssertTrue(payButton.waitForExistence(timeout: 5))
        XCTAssertEqual(payButton.value as? String, "0")
        payButton.tap()
        XCTAssertEqual(payButton.value as? String, "1")

        // 3. Tap Mark on the floating bar and assert the mark count goes up
        markButton.tap()
        let markUpdatedPredicate = NSPredicate(format: "value == '1'")
        let markExpectation = XCTNSPredicateExpectation(predicate: markUpdatedPredicate, object: markButton)
        XCTAssertEqual(XCTWaiter().wait(for: [markExpectation], timeout: 5), .completed)
        XCTAssertTrue(markButton.label.contains("Mark (1)"))

        // 4. Tap the pill title area to expand the card and verify expanded controls respond
        expandButton.tap()
        let collapseButton = app.buttons["HollerKitQuestCollapseButton"]
        XCTAssertTrue(collapseButton.waitForExistence(timeout: 5))
        let step0Button = app.buttons["HollerKitQuestStep_0"]
        XCTAssertTrue(step0Button.waitForExistence(timeout: 5))
        XCTAssertEqual(step0Button.value as? String, "unchecked")
        step0Button.tap()
        XCTAssertEqual(step0Button.value as? String, "checked")
        step0Button.tap()
        XCTAssertEqual(step0Button.value as? String, "unchecked")

        // 5. Tap Done and assert the result sheet appears
        doneButton.tap()
        let submitButton = app.buttons["HollerKitQuestResultSubmitButton"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Complete Quest"].exists)

        // 6. Tap the blank right side of the Fail outcome row and verify it selects Fail
        let failOption = app.buttons["HollerKitQuestResultOption_fail"]
        XCTAssertTrue(failOption.waitForExistence(timeout: 5))
        XCTAssertEqual(failOption.value as? String, "unselected")
        failOption.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertEqual(failOption.value as? String, "selected")

        // 7. Tap Check All in the Steps section and verify all steps become checked
        let stepsHeader = app.staticTexts["HollerKitQuestResultStepsHeader"]
        XCTAssertTrue(stepsHeader.waitForExistence(timeout: 5))
        XCTAssertTrue(stepsHeader.label.localizedCaseInsensitiveContains("Steps (0/3)"))
        let checkAllButton = app.buttons["HollerKitQuestResultCheckAllStepsButton"]
        XCTAssertTrue(checkAllButton.waitForExistence(timeout: 5))
        checkAllButton.tap()
        XCTAssertTrue(stepsHeader.label.localizedCaseInsensitiveContains("Steps (3/3)"))
    }

    @MainActor
    func testNormalScrollAndPanDoesNotTriggerHollerKit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--skip-auto-report"]
        app.launch()

        let scrollView = app.scrollViews["DemoCheckoutScrollView"]
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5))

        // Perform normal vertical swipe / scroll
        scrollView.swipeUp()
        scrollView.swipeDown()

        // Verify neither bug report nor quest board was triggered by scrolling
        XCTAssertFalse(app.navigationBars["Report a Bug"].exists)
        XCTAssertFalse(app.navigationBars["Complete Quest"].exists)
        XCTAssertFalse(app.navigationBars["Quests"].exists)
    }

    @MainActor
    func testBackSwipeNavigationDoesNotTriggerHollerKit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--skip-auto-report"]
        app.launch()

        // 1. Navigate to Order Details
        let detailsLink = app.buttons["DemoOrderDetailsLink"]
        XCTAssertTrue(detailsLink.waitForExistence(timeout: 5))
        detailsLink.tap()

        XCTAssertTrue(app.navigationBars["Order Details"].waitForExistence(timeout: 5))

        // 2. Perform gesture starting near screen edge (x=0.02, < 24pt edge inset) moving right
        let startCoord = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        let endCoord = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        startCoord.press(forDuration: 0.05, thenDragTo: endCoord)

        // 3. Confirm edge gesture did not trigger HollerKit bug report or quests
        XCTAssertFalse(app.navigationBars["Report a Bug"].exists)
        XCTAssertFalse(app.navigationBars["Quests"].exists)

        // 4. Return to Checkout via back button and confirm navigation is unaffected
        let backButton = app.navigationBars["Order Details"].buttons.element(boundBy: 0)
        if backButton.exists {
            backButton.tap()
        }
        XCTAssertTrue(app.navigationBars["Checkout"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Report a Bug"].exists)
        XCTAssertFalse(app.navigationBars["Quests"].exists)
    }
}
