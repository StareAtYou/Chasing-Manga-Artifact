import XCTest
final class MangaFlowTests: XCTestCase {
    @MainActor func testChooseSourceAndReaderModes() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        let work = app.buttons["打开 原创样本"].firstMatch; XCTAssertTrue(work.waitForExistence(timeout: 15)); activate(work)
        let source = app.buttons["选择此来源"].firstMatch; XCTAssertTrue(source.waitForExistence(timeout: 10)); activate(source)
        let chapter = app.buttons["chapter-0"]; XCTAssertTrue(chapter.waitForExistence(timeout: 10)); activate(chapter)
        let reader = app.otherElements["reader"]; XCTAssertTrue(reader.waitForExistence(timeout: 10))
        let settings = app.buttons["reader-settings"]; activate(settings); activate(app.buttons["逐页阅读"])
        let next = app.buttons["下一页"]; XCTAssertTrue(next.waitForExistence(timeout: 10)); activate(next)
        XCTAssertTrue(app.staticTexts["2 / 4"].waitForExistence(timeout: 10))
        activate(settings); activate(app.buttons["从右向左"])
        #if os(macOS)
        activate(settings); activate(app.buttons["双页阅读"])
        app.typeKey(.rightArrow, modifierFlags: [])
        #else
        let zoom = app.scrollViews["page-zoom"]; XCTAssertTrue(zoom.waitForExistence(timeout: 10)); zoom.pinch(withScale: 1.5, velocity: 1)
        #endif
        activate(settings); activate(app.buttons["纵向滚动"])
        let image = app.otherElements["comic-page-0"].firstMatch
        if image.exists { image.swipeUp() }
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
    }
    @MainActor private func activate(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }
}
