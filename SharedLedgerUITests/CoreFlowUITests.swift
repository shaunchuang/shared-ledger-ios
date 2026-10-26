import XCTest

/// Drives the first thing a new user does: create a group, give it an account
/// to pay from, then record an expense in it. Elements are found by
/// accessibility identifier so the test does not depend on the simulator's
/// language.
final class CoreFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("-ui-testing")
        app.launch()
    }

    func testCreateGroupThenRecordExpense() throws {
        createGroup(named: "UITest Trip", owner: "Shaun")
        // A new group has no accounts, and an expense cannot be saved without one.
        addAccount(named: "Cash", toGroupNamed: "UITest Trip")

        let tabBar = app.tabBars.firstMatch
        tabBar.buttons.element(boundBy: 1).tap()

        // The quick-entry button under the list, not the toolbar "+" menu: on the
        // iOS 18 simulator CI uses, XCTest cannot compute a hit point for that menu.
        let addExpense = app.buttons["quickEntry.expense"]
        XCTAssertTrue(addExpense.waitForExistence(timeout: 10))
        addExpense.tap()

        let amount = app.textFields["transaction.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText("120")

        let save = app.buttons["transaction.save"]
        XCTAssertTrue(save.isEnabled)
        tap(save)

        // The list was empty before, so any row showing the amount is the new entry.
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "120"))
                .firstMatch.waitForExistence(timeout: 5)
        )
    }

    private func createGroup(named name: String, owner: String) {
        app.tabBars.firstMatch.buttons.element(boundBy: 4).tap()

        let groupManagement = app.buttons["settings.groupManagement"]
        XCTAssertTrue(groupManagement.waitForExistence(timeout: 5))
        groupManagement.tap()

        let create = app.buttons["groups.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()

        let nameField = app.textFields["createGroup.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(name)

        let ownerField = app.textFields["createGroup.ownerName"]
        ownerField.tap()
        ownerField.typeText(owner)

        app.buttons["createGroup.submit"].tap()

        // Creating a group goes straight on to CloudKit sharing, which has no
        // container behind the in-memory store. Whatever it shows is dismissed
        // here; the group itself is already saved.
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 5) {
            alert.buttons.firstMatch.tap()
        }
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
    }

    private func addAccount(named name: String, toGroupNamed group: String) {
        app.staticTexts[group].tap()

        let accounts = app.buttons["groupDetail.accounts"]
        for _ in 0..<4 where !accounts.isHittable {
            app.swipeUp()
        }
        accounts.tap()

        let add = app.buttons["accounts.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()

        let nameField = app.textFields["newAccount.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(name)

        app.buttons["newAccount.save"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
    }

    /// Toolbar buttons can exist with no hit point on older simulators; tapping
    /// the element's centre still reaches them.
    private func tap(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }
}
