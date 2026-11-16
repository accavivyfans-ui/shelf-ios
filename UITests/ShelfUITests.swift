import XCTest

final class ShelfUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["SHELF_SHARE"] = ProcessInfo.processInfo.environment["SHELF_SHARE"] ?? ""
        app.launchEnvironment["SHELF_NOSYNC"] = "1"
        app.launch()
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func waitIndexed() {
        let banner = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '정리하는 중'")).firstMatch
        let deadline = Date().addingTimeInterval(150)
        while banner.exists, Date() < deadline { sleep(2) }
    }

    func testTour() throws {
        XCTAssertTrue(app.tabBars.buttons["서재"].waitForExistence(timeout: 20), "share link setup failed")
        sleep(3)
        shot("01-home-indexing")
        waitIndexed()
        app.tabBars.buttons["서재"].tap()
        sleep(6)
        shot("02-library")
        sleep(25)
        shot("02b-library-covers")

        app.tabBars.buttons["기출"].tap()
        sleep(2)
        shot("03-exams")
        let paper = app.buttons.containing(NSPredicate(format: "label CONTAINS '국어'")).firstMatch
        if paper.waitForExistence(timeout: 10) {
            paper.tap()
            sleep(20)
            shot("04-pdf-reader")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(2)
            shot("05-pdf-chrome")
            let close = app.buttons["xmark"].firstMatch
            if !close.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(2) }
            if close.exists { close.tap() }
            sleep(3)
        }

        app.tabBars.buttons["검색"].tap()
        let field = app.textFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("불편한 편의점\n")
            sleep(2)
            shot("06-search")
            let result = app.buttons.containing(NSPredicate(format: "label CONTAINS '불편한'")).firstMatch
            if result.waitForExistence(timeout: 5) {
                sleep(1)
                result.tap()
                sleep(3)
                if result.exists && result.isHittable { result.tap() }
                sleep(25)
                shot("07-epub-reader")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
                sleep(2)
                shot("08-epub-next-page")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                sleep(1)
                shot("09-epub-chrome")
            }
        }
    }
}
