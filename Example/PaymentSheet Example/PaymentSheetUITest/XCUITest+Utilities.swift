//
//  XCUITest+Utilities.swift
//  PaymentSheetUITest
//
//  Created by Yuki Tokuhiro on 8/20/21.
//  Copyright © 2021 stripe-ios. All rights reserved.
//

import XCTest

// There seems to be an issue with our SwiftUI buttons - XCTest fails to scroll to the button's position.
// Work around this by targeting a coordinate inside the button.
// https://stackoverflow.com/questions/33422681/xcode-ui-test-ui-testing-failure-failed-to-scroll-to-visible-by-ax-action
extension XCUIElement {
    func forceTapElement() {
        if self.isHittable {
            self.tap()
        } else {
            // Tap the middle of the element.
            // (Sometimes the edges of rounded buttons aren't tappable in certain web elements.)
            let coordinate: XCUICoordinate = self.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            coordinate.tap()
        }
    }

    func forceTapWhenHittableInTestCase(_ testCase: XCTestCase) {
        let predicate = NSPredicate(format: "hittable == true")
        testCase.expectation(for: predicate, evaluatedWith: self, handler: nil)
        testCase.waitForExpectations(timeout: 15.0, handler: nil)
        self.forceTapElement()
    }

    @discardableResult
    func waitForExistenceAndTap(timeout: TimeInterval = 4.0) -> Bool {
        guard waitForExistenceIfNeeded(timeout: timeout) else {
            return false
        }
        forceTapElement()
        return true
    }
    
    @discardableResult
    func waitForExistenceIfNeeded(timeout: TimeInterval = 4.0) -> Bool {
        if !exists  {
            return waitForExistenceIfNeeded(timeout: timeout)
        }
        return true
    }

    func firstDescendant(withLabel label: String) -> XCUIElement {
        return descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", label)
        ).firstMatch
    }
}

// MARK: - XCUIApplication

extension XCUIApplication {
    /// Types a text using the software keyboard.
    ///
    /// This method is significantly slower than `XCUIElement.typeText()` but it works with custom controls.
    ///
    /// - Parameter text: Text to type.
    func typeTextWithKeyboard(_ text: String) {
        for key in text {
            self.keys[String(key)].tap()
        }
    }
}

// https://gist.github.com/jlnquere/d2cd529874ca73624eeb7159e3633d0f
func scroll(collectionView: XCUIElement, toFindCellWithId identifier: String) -> XCUIElement? {
    return scroll(collectionView: collectionView) { collectionView in
        let cell = collectionView.cells[identifier]
        if cell.exists {
            return cell
        }
        return nil
    }
}

func scroll(collectionView: XCUIElement, toFindButtonWithId identifier: String) -> XCUIElement? {
    return scroll(collectionView: collectionView) { collectionView in
        let button = collectionView.buttons[identifier].firstMatch
        if button.exists {
            return button
        }
        return nil
    }
}

func scroll(collectionView: XCUIElement, toFindElementInCollectionView getElementInCollectionView: (XCUIElement) -> XCUIElement?) -> XCUIElement? {
    guard collectionView.elementType == .collectionView else {
        fatalError("XCUIElement is not a collectionView.")
    }

    var reachedTheEnd = false
    var allVisibleElements = [String]()

    while !reachedTheEnd {
        // Did we find our element ?
        if let element = getElementInCollectionView(collectionView) {
           return element
        }

        // If not: we store the list of all the elements we've got in the CollectionView
        let allElements = collectionView.cells.allElementsBoundByIndex.map({ $0.identifier })

        // Did we read then end of the CollectionView ?
        // i.e: do we have the same elements visible than before scrolling ?
        reachedTheEnd = (allElements == allVisibleElements)
        allVisibleElements = allElements

        // Then, we do a scroll right on the scrollview
        let startCoordinate = collectionView.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.99))
        startCoordinate.press(forDuration: 0.01, thenDragTo: collectionView.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.99)))
    }
    return nil
}

extension XCTestCase {
    func fillCardData(_ app: XCUIApplication,
                      container: XCUIElement? = nil,
                      cardNumber: String? = nil,
                      postalEnabled: Bool = true) throws {
        let context = container ?? app

        let numberField = context.textFields["Card number"].firstMatch
        numberField.forceTapWhenHittableInTestCase(self)
        app.typeText(cardNumber ?? "4242424242424242")
        app.typeText("1228") // Expiry
        app.typeText("123") // CVC
        if postalEnabled {
            app.toolbars.buttons["Done"].firstMatch.tap() // Country picker toolbar's "Done" button
            app.typeText("12345") // Postal
        }
    }

    func fillUSBankData(_ app: XCUIApplication,
                        container: XCUIElement? = nil) throws {
        let context = container ?? app
        let nameField = context.textFields["Full name"].firstMatch
        nameField.forceTapWhenHittableInTestCase(self)
        app.typeText("John Doe")

        let emailField = context.textFields["Email"].firstMatch
        emailField.forceTapWhenHittableInTestCase(self)
        app.typeText("test-\(UUID().uuidString)@example.com")
    }
    func fillUSBankData_microdeposits(_ app: XCUIApplication,
                                      container: XCUIElement? = nil) throws {
        let context = container ?? app
        let routingField = context.textFields["manual_entry_routing_number_text_field"].firstMatch
        routingField.forceTapWhenHittableInTestCase(self)
        app.typeText("110000000")

        let acctField = context.textFields["manual_entry_account_number_text_field"].firstMatch
        acctField.forceTapWhenHittableInTestCase(self)
        app.typeText("000123456789")

        // Dismiss keyboard, otherwise we can not see the next field
        // This is only an artifact in the (test) native version of the flow
        app.scrollViews.firstMatch.swipeUp()

        let acctConfirmField = context.textFields["manual_entry_account_number_confirmation_text_field"].firstMatch
        acctConfirmField.forceTapWhenHittableInTestCase(self)
        app.typeText("000123456789")

        // Dismiss keyboard again otherwise we can not see the continue button
        // This is only an artifact in the (test) native version of the flow
        app.scrollViews.firstMatch.swipeUp()
    }
    func fillSepaData(_ app: XCUIApplication,
                      container: XCUIElement? = nil) throws {
        let context = container ?? app
        let nameField = context.textFields["Full name"].firstMatch
        nameField.forceTapWhenHittableInTestCase(self)
        app.typeText("John Doe")

        let emailField = context.textFields["Email"].firstMatch
        emailField.forceTapWhenHittableInTestCase(self)
        app.typeText("test@example.com")

        let ibanField = context.textFields["IBAN"].firstMatch
        ibanField.forceTapWhenHittableInTestCase(self)
        app.typeText("DE89370400440532013000")

        let addressLine1 = context.textFields["Address line 1"].firstMatch
        addressLine1.forceTapWhenHittableInTestCase(self)
        app.typeText("123 Main")
        context.buttons["Return"].firstMatch.tap()

        // Skip address 2
        context.buttons["Return"].firstMatch.tap()

        app.typeText("San Francisco")
        context.buttons["Return"].firstMatch.tap()

        context.pickerWheels.element.adjust(toPickerWheelValue: "California")
        context.buttons["Done"].firstMatch.tap()

        app.typeText("94016")
        context.buttons["Done"].firstMatch.tap()
    }

    func waitToDisappear(_ target: Any?) {
        let exists = NSPredicate(format: "exists == 0")
        expectation(for: exists, evaluatedWith: target, handler: nil)
        waitForExpectations(timeout: 60.0, handler: nil)
    }

    func waitForNItemsExistence(_ target: Any?, count: Int) {
        let elementExistsPredicate = NSPredicate(format: "count == %d", count)
        expectation(for: elementExistsPredicate, evaluatedWith: target, handler: nil)
        waitForExpectations(timeout: 10.0, handler: nil)
    }

    func reload(_ app: XCUIApplication, settings: PaymentSheetTestPlaygroundSettings) {
        app.buttons["Reload"].firstMatch.tap()
        waitForReload(app, settings: settings)
    }

    func waitForReload(_ app: XCUIApplication, settings: PaymentSheetTestPlaygroundSettings) {
        if settings.uiStyle == .paymentSheet {
            let presentButton = app.buttons["Present PaymentSheet"].firstMatch
            expectation(
                for: NSPredicate(format: "enabled == true"),
                evaluatedWith: presentButton,
                handler: nil
            )
            waitForExpectations(timeout: 10, handler: nil)
        } else {
            let confirm = app.buttons["Confirm"].firstMatch
            expectation(
                for: NSPredicate(format: "enabled == true"),
                evaluatedWith: confirm,
                handler: nil
            )
            waitForExpectations(timeout: 10, handler: nil)
        }
    }
    func loadPlayground(_ app: XCUIApplication, _ settings: PaymentSheetTestPlaygroundSettings) {
        if #available(iOS 15.0, *) {
            // Doesn't work on 16.4. Seems like a bug, can't see any confirmation that this works online.
            //   var urlComponents = URLComponents(string: "stripe-paymentsheet-example://playground")!
            //   urlComponents.query = settings.base64Data
            //   app.open(urlComponents.url!)
            // This should work, but we get an "Open in 'PaymentSheet Example'" consent dialog the first time we run it.
            // And while the dialog is appearing, `open()` doesn't return, so we can't install an interruption handler or anything to handle it.
            //   XCUIDevice.shared.system.open(urlComponents.url!)
            app.launchEnvironment = app.launchEnvironment.merging(["STP_PLAYGROUND_DATA": settings.base64Data]) { (_, new) in new }
            app.launch()
        } else {
            XCTFail("This test is only supported on iOS 15.0 or later.")
        }
        waitForReload(app, settings: settings)
    }
    func waitForReload(_ app: XCUIApplication, settings: CustomerSheetTestPlaygroundSettings) {
        let paymentMethodButton = app.buttons["Payment method"].firstMatch
        expectation(
            for: NSPredicate(format: "enabled == true"),
            evaluatedWith: paymentMethodButton,
            handler: nil
        )
        waitForExpectations(timeout: 10, handler: nil)
    }
    func loadPlayground(_ app: XCUIApplication, _ settings: CustomerSheetTestPlaygroundSettings) {
        if #available(iOS 15.0, *) {
            app.launchEnvironment = app.launchEnvironment.merging(["STP_CUSTOMERSHEET_PLAYGROUND_DATA": settings.base64Data]) { (_, new) in new }
            app.launch()
        } else {
            XCTFail("This test is only supported on iOS 15.0 or later.")
        }
        waitForReload(app, settings: settings)
    }
}
