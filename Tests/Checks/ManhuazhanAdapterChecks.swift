import Foundation
import MangaCore
struct FixturePageRenderer: PageRenderer {
    let page: RenderedPage
    func render(url: URL, source: Source, interactive: Bool) async throws -> RenderedPage { page }
}
public let manhuazhanAdapterChecks: [Check] = [
    Check("ManhuazhanAdapterTests.manhuazhanLinksPreserveSemanticIDs") {
        let source = BuiltinSources.candidates()[0]; let url = source.baseURL.appendingPathComponent("comic/219424")
        let client = FixtureHTTPClient([url.absoluteString: textResponse(try fixtureText("manhuazhan-detail"), url)])
        let adapter = ManhuazhanAdapter(); let context = ParserContext(source: source, client: client)
        let work = try await adapter.details(url: url, context: context); let chapters = try await adapter.chapters(work: work, context: context)
        try expect(work.id.externalID == "/comic/219424" && chapters.map { $0.id.externalID } == ["/chapter/219424-39758.html", "/chapter/219424-39759.html"], "Keep semantic chapter IDs")
    },
    Check("ManhuazhanAdapterTests.challengePageDoesNotLookLikeComic") {
        let source = BuiltinSources.candidates()[0]; let url = source.baseURL
        let client = FixtureHTTPClient([url.absoluteString: textResponse("<title>Just a moment</title><h1>验证</h1>", url)])
        do { _ = try await ManhuazhanAdapter().details(url: url, context: ParserContext(source: source, client: client)); throw CheckFailure(description: "Challenge is not comic content") }
        catch MangaError.verificationRequired { }
    },
    Check("ManhuazhanAdapterTests.searchChallengeIsNotEmptyResults") {
        let source = BuiltinSources.candidates()[0]; let url = source.baseURL.appendingPathComponent("search")
        let client = FixtureHTTPClient([url.absoluteString: textResponse("<title>安全验证 - 漫画站</title>", url)])
        do { _ = try await ManhuazhanAdapter().search(query: "非人哉", context: ParserContext(source: source, client: client)); throw CheckFailure(description: "Search challenge must be explicit") }
        catch MangaError.verificationRequired { }
    },
    Check("ManhuazhanAdapterTests.manhuazhanCompletePageList") {
        let source = BuiltinSources.candidates()[0]; let chapter = Samples.chapter(Samples.work(source)); let id = UUID()
        let client = FixtureHTTPClient([chapter.url.absoluteString: textResponse("<div id='ChapterContent'></div><script>var DATA='sample';</script>", chapter.url)])
        let renderer = FixturePageRenderer(page: RenderedPage(url: chapter.url, html: "<div id='ChapterContent'></div>", accessContextID: id, metadata: ["manhuazhan.pages": "[{\"url\":\"https://images.test/1.jpg\"},{\"url\":\"https://images.test/2.jpg\"},{\"url\":\"https://images.test/3.jpg\"}]"]))
        let pages = try await ManhuazhanAdapter().pages(chapter: chapter, context: ParserContext(source: source, client: client, renderer: renderer))
        try expect(pages.count == 3 && pages.last?.request.url.lastPathComponent == "3.jpg" && pages[0].request.accessContextID == id, "Complete browser-generated list and scoped access context")
    },
    Check("HTTPClientTests.crossOriginRedirectDropsPOSTBody") {
        var request = URLRequest(url: Samples.sourceB.baseURL); request.httpMethod = "POST"; request.httpBody = Data("password=secret".utf8)
        let safe = RedirectPolicy.sanitize(request, from: Samples.sourceA.baseURL)
        try expect(safe.httpBody == nil, "POST body cannot forward secrets to another origin")
    }
]
