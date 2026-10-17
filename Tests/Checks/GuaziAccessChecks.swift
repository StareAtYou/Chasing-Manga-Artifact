import Foundation
import MangaCore
private func guaziReaderChapter(_ external: String = "2001") -> Chapter {
    let source = BuiltinSources.candidates()[1]
    let work = SourceWorkID(sourceID: source.id, externalID: "/comic.php?id=100")
    return Chapter(id: ChapterID(sourceWorkID: work, externalID: "/chapter.php?id=" + external), title: external, url: URL(string: "https://www.guazimanhua.com/chapter.php?id=" + external)!, ordinal: 0)
}
private struct RefererRequiredGuaziClient: HTTPClient {
    func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        guard request.referer?.absoluteString == "https://www.guazimanhua.com/comic.php?id=100", request.headers["Accept"]?.contains("text/html") == true else { throw MangaError.accessRestricted(403) }
        return textResponse(try fixtureText("guazi-chapter"), request.url)
    }
}
private actor ConcurrentGuaziRenderer: PageRenderer {
    var active = 0; var peak = 0
    func render(url: URL, source: Source, interactive: Bool) async throws -> RenderedPage {
        active += 1; peak = max(peak, active); defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(15))
        return RenderedPage(url: url, html: try fixtureText("guazi-chapter"))
    }
}
public let guaziAccessChecks: [Check] = [
    Check("GuaziAccessTests.chapterRequestIncludesWorkReadingContext") {
        let source = BuiltinSources.candidates()[1]
        let pages = try await GuaziAdapter().pages(chapter: guaziReaderChapter(), context: ParserContext(source: source, client: RefererRequiredGuaziClient()))
        try expect(pages.count == 2 && pages.map(\.id.externalID) == ["1","2"], "Chapter requests need the work referer and HTML Accept while preserving stable page IDs")
    },
    Check("GuaziAccessTests.forbiddenChapterUsesScopedBrowserPage") {
        let source = BuiltinSources.candidates()[1]; let chapter = guaziReaderChapter(); let token = UUID()
        let client = FixtureHTTPClient([chapter.url.absoluteString: ResourceResponse(data: Data(), finalURL: chapter.url, statusCode: 403)])
        let browser = FixturePageRenderer(page: RenderedPage(url: chapter.url, html: try fixtureText("guazi-chapter"), accessContextID: token, metadata: ["reader.userAgent":"FixtureBrowser/1"]))
        let pages = try await GuaziAdapter().pages(chapter: chapter, context: ParserContext(source: source, client: client, renderer: browser))
        try expect(pages.count == 2 && pages.allSatisfy { $0.request.accessContextID == token && $0.request.referer == chapter.url && $0.request.headers["User-Agent"] == "FixtureBrowser/1" }, "403 recovery must use the browser's same chapter and public request context")
    },
    Check("GuaziAccessTests.browserChallengeAndLoginRemainExplicit") {
        let source = BuiltinSources.candidates()[1]; let chapter = guaziReaderChapter()
        for title in ["Just a moment", "请登录"] {
            let client = FixtureHTTPClient([chapter.url.absoluteString: ResourceResponse(data: Data(), finalURL: chapter.url, statusCode: 403)])
            let browser = FixturePageRenderer(page: RenderedPage(url: chapter.url, html: "<title>" + title + "</title>"))
            do { _ = try await GuaziAdapter().pages(chapter: chapter, context: ParserContext(source: source, client: client, renderer: browser)); throw CheckFailure(description: "Restricted page cannot be treated as comic images") }
            catch MangaError.verificationRequired { try expect(title == "Just a moment", "Verification remains distinct") }
            catch MangaError.requiresLogin { try expect(title == "请登录", "Login remains distinct") }
        }
    },
    Check("GuaziAccessTests.browserCannotSubstituteAnotherChapter") {
        let source = BuiltinSources.candidates()[1]; let chapter = guaziReaderChapter()
        for url in [URL(string: "https://other.test/chapter.php?id=2001")!,guaziReaderChapter("2002").url] {
            let client = FixtureHTTPClient([chapter.url.absoluteString: ResourceResponse(data: Data(), finalURL: chapter.url, statusCode: 403)])
            let browser = FixturePageRenderer(page: RenderedPage(url: url, html: try fixtureText("guazi-chapter")))
            do { _ = try await GuaziAdapter().pages(chapter: chapter, context: ParserContext(source: source, client: client, renderer: browser)); throw CheckFailure(description: "Wrong chapter accepted") }
            catch MangaError.invalidURL { }
        }
    },
    Check("GuaziAccessTests.concurrentFallbackDoesNotCancelSharedBrowser") {
        let source = BuiltinSources.candidates()[1]; let first = guaziReaderChapter(), second = guaziReaderChapter("2002")
        let client = FixtureHTTPClient(Dictionary(uniqueKeysWithValues: [first,second].map { ($0.url.absoluteString, ResourceResponse(data: Data(), finalURL: $0.url, statusCode: 403)) }))
        let browser = ConcurrentGuaziRenderer(); let context = ParserContext(source: source, client: client, renderer: browser)
        async let a = GuaziAdapter().pages(chapter: first, context: context)
        async let b = GuaziAdapter().pages(chapter: second, context: context)
        let results = try await [a,b]; let peak = await browser.peak
        try expect(results.allSatisfy { $0.count == 2 } && peak == 1, "Two chapter preparations must not navigate the same WKWebView at once")
    },
    Check("GuaziAccessTests.absentBrowserKeepsOriginalForbiddenError") {
        let source = BuiltinSources.candidates()[1]; let chapter = guaziReaderChapter()
        let client = FixtureHTTPClient([chapter.url.absoluteString: ResourceResponse(data: Data(), finalURL: chapter.url, statusCode: 403)])
        do { _ = try await GuaziAdapter().pages(chapter: chapter, context: ParserContext(source: source, client: client)); throw CheckFailure(description: "403 must not disappear without a browser") }
        catch MangaError.accessRestricted(403) { }
    }
]
