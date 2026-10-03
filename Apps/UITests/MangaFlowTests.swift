import XCTest
final class MangaFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    @MainActor func testChooseSourceAndReaderModes() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        let work = app.buttons["打开 原创样本"].firstMatch; XCTAssertTrue(work.waitForExistence(timeout: 15)); activate(work)
        let source = app.buttons["选择此来源"].firstMatch; XCTAssertTrue(source.waitForExistence(timeout: 10)); activate(source)
        let chapter = app.buttons["chapter-0"]; XCTAssertTrue(chapter.waitForExistence(timeout: 10)); activate(chapter)
        waitUntilReady(app)
        chooseMode("逐页阅读", app: app); waitUntilReady(app)
        // Choosing the already active mode must not freeze readiness/progress.
        chooseMode("逐页阅读", app: app); waitUntilReady(app)
        let next = app.buttons["下一页"]; XCTAssertTrue(next.waitForExistence(timeout: 10)); XCTAssertTrue(next.isEnabled); activate(next); waitUntilReady(app)
        XCTAssertTrue(app.staticTexts["2 / 4"].waitForExistence(timeout: 10))
        chooseMode("从右向左", app: app)
        #if os(macOS)
        chooseMode("双页阅读", app: app); waitUntilReady(app)
        app.typeKey(.leftArrow, modifierFlags: []); waitUntilReady(app)
        XCTAssertTrue(app.staticTexts["4 / 4"].waitForExistence(timeout: 10))
        #else
        let zoom = app.scrollViews["page-zoom"]; XCTAssertTrue(zoom.waitForExistence(timeout: 10)); zoom.pinch(withScale: 1.5, velocity: 1)
        #endif
        chooseMode("纵向滚动", app: app); waitUntilReady(app)
        let scroll = app.scrollViews["reader-scroll"]; XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        #if os(macOS)
        scroll.scroll(byDeltaX: 0, deltaY: 200)
        #else
        scroll.swipeUp()
        #endif
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
    }
    @MainActor func testRecommendationsPaginationAndShelfDownloadSheet() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        #if os(macOS)
        let recommendation = app.outlines.staticTexts["推荐"].firstMatch
        if recommendation.waitForExistence(timeout: 10) { recommendation.click() } else { activate(app.staticTexts["推荐"].firstMatch) }
        #else
        activate(app.tabBars.buttons["推荐"])
        #endif
        let genre = app.buttons["冒险"]; XCTAssertTrue(genre.waitForExistence(timeout: 15)); activate(genre)
        let next = app.buttons["catalog-next-page"].firstMatch; XCTAssertTrue(next.waitForExistence(timeout: 10)); activate(next)
        let newWork = app.buttons["打开 海边旅人 · 本地样本源 1"].firstMatch; XCTAssertTrue(newWork.waitForExistence(timeout: 10)); activate(newWork)
        let whole = app.buttons["download-whole-work"].firstMatch; XCTAssertTrue(whole.waitForExistence(timeout: 10)); activate(whole)
        let offline = app.buttons["离线阅读"].firstMatch; XCTAssertTrue(offline.waitForExistence(timeout: 15))
        activate(offline); waitUntilReady(app)
    }
    @MainActor private func waitUntilReady(_ app: XCUIApplication) { XCTAssertTrue(app.staticTexts["reader-ready"].waitForExistence(timeout: 15)) }
    @MainActor private func chooseMode(_ title: String, app: XCUIApplication) {
        #if os(macOS)
        let menu = app.popUpButtons["reader-settings"]; XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.click(); let item = app.menuItems[title]; XCTAssertTrue(item.waitForExistence(timeout: 5)); item.click()
        #else
        let menu = app.buttons["reader-settings"]; XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap(); let item = app.buttons[title]; XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
        #endif
    }
    @MainActor private func activate(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }
}
