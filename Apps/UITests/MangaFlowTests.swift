import XCTest
final class MangaFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    @MainActor func testSourceCardOpensReaderAndReaderModes() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        let work = app.buttons["打开 原创样本"].firstMatch; XCTAssertTrue(work.waitForExistence(timeout: 15)); activate(work)
        XCTAssertFalse(app.buttons["选择此来源"].exists)
        let source = app.buttons["read-source-card"].firstMatch; XCTAssertTrue(source.waitForExistence(timeout: 10))
        // Tap the card's metadata area, away from the embedded controls.
        let cardBackground = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        #if os(macOS)
        cardBackground.click()
        #else
        cardBackground.tap()
        #endif
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
    @MainActor func testContinuousChapterScroll() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        let work = app.buttons["打开 原创样本"].firstMatch; XCTAssertTrue(work.waitForExistence(timeout: 15)); activate(work)
        let source = app.buttons["章节目录"].firstMatch; XCTAssertTrue(source.waitForExistence(timeout: 10)); activate(source)
        let chapter = app.buttons["chapter-1"]; XCTAssertTrue(chapter.waitForExistence(timeout: 10)); activate(chapter)
        waitUntilReady(app)
        let scroll = app.scrollViews["reader-scroll"]; XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        // Opening the second chapter must retain its first page despite prepending chapter one.
        XCTAssertTrue(readerTitle("第2话", app: app).waitForExistence(timeout: 5))
        scrollReader(scroll, up: true)
        XCTAssertTrue(readerTitle("第1话", app: app).waitForExistence(timeout: 10))
        for _ in 0..<6 {
            if readerTitle("第2话", app: app).exists { break }
            scrollReader(scroll, up: false)
        }
        XCTAssertTrue(readerTitle("第2话", app: app).waitForExistence(timeout: 5))
        waitUntilReady(app)
    }
    @MainActor private func readerTitle(_ title: String, app: XCUIApplication) -> XCUIElement {
        #if os(macOS)
        return app.windows[title]
        #else
        return app.navigationBars[title]
        #endif
    }
    @MainActor private func scrollReader(_ scroll: XCUIElement, up: Bool) {
        #if os(macOS)
        scroll.scroll(byDeltaX: 0, deltaY: up ? -600 : 600)
        #else
        if up { scroll.swipeDown() } else { scroll.swipeUp() }
        #endif
    }
    @MainActor func testRecommendationsPaginationAndShelfDownloadSheet() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        #if os(macOS)
        let recommendation = app.outlines.staticTexts["推荐"].firstMatch
        if recommendation.waitForExistence(timeout: 10) { recommendation.click() } else { activate(app.staticTexts["推荐"].firstMatch) }
        #else
        activate(app.tabBars.buttons["推荐"])
        #endif
        let genres = app.buttons["recommendation-genres"]
        XCTAssertTrue(genres.waitForExistence(timeout: 15)); XCTAssertFalse(app.buttons["冒险"].exists)
        activate(genres); XCTAssertTrue(app.buttons["冒险"].waitForExistence(timeout: 5))
        activate(genres); XCTAssertFalse(app.buttons["冒险"].exists)
        activate(genres)
        let genre = app.buttons["冒险"]; XCTAssertTrue(genre.waitForExistence(timeout: 5)); activate(genre)
        let next = app.buttons["catalog-next-page"].firstMatch; XCTAssertTrue(next.waitForExistence(timeout: 10)); activate(next)
        let newWork = app.buttons["打开 海边旅人 · 本地样本源 1"].firstMatch; XCTAssertTrue(newWork.waitForExistence(timeout: 10)); activate(newWork)
        let whole = app.buttons["download-whole-work"].firstMatch; XCTAssertTrue(whole.waitForExistence(timeout: 10)); activate(whole)
        let offline = app.buttons["离线阅读"].firstMatch; XCTAssertTrue(offline.waitForExistence(timeout: 15))
        activate(offline); waitUntilReady(app)
    }
    @MainActor func testDiscoverySearchScope() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        #if os(macOS)
        let discovery = app.outlines.staticTexts["发现"].firstMatch
        XCTAssertTrue(discovery.waitForExistence(timeout: 15)); discovery.click()
        #else
        let discovery = app.tabBars.buttons["发现"]
        XCTAssertTrue(discovery.waitForExistence(timeout: 15)); discovery.tap()
        #endif
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10)); activate(field); field.typeText("demo")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "搜索结果 · 6")).firstMatch.waitForExistence(timeout: 10))
        chooseSearchScope("本地样本源 2", app: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "搜索结果 · 3")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["打开 原创样本 · 本地样本源 1"].exists)
        XCTAssertTrue(app.buttons["打开 原创样本 · 本地样本源 2"].exists)
        chooseSearchScope("全部漫画源", app: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "搜索结果 · 6")).firstMatch.waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
    }
    @MainActor private func chooseSearchScope(_ title: String, app: XCUIApplication) {
        #if os(macOS)
        let menu = app.popUpButtons["discovery.searchScope"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.click()
        let item = app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.click()
        #else
        let menu = app.buttons["discovery.searchScope"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap()
        let item = app.buttons[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
        #endif
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
