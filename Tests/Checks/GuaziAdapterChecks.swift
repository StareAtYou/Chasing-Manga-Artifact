import Foundation
import MangaCore
import MangaPlatform
public func fixtureText(_ name: String) throws -> String { try String(contentsOf: Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures")!, encoding: .utf8) }
public let guaziAdapterChecks: [Check] = [
    Check("GuaziAdapterTests.guaziDirectoryAndPages") {
        let source = BuiltinSources.candidates()[1]; let url = source.baseURL.appendingPathComponent("comic.php").appending(queryItems: [URLQueryItem(name: "id", value: "100")])
        let chapterURL = URL(string: "https://www.guazimanhua.com/chapter.php?id=2001")!
        let client = FixtureHTTPClient([url.absoluteString: textResponse(try fixtureText("guazi-detail"), url), chapterURL.absoluteString: textResponse(try fixtureText("guazi-chapter"), chapterURL)])
        let context = ParserContext(source: source, client: client); let adapter = GuaziAdapter()
        let work = try await adapter.details(url: url, context: context); let chapters = try await adapter.chapters(work: work, context: context)
        try expect(work.id.externalID == "/comic.php?id=100" && chapters.map { $0.id.externalID } == ["/chapter.php?id=2001", "/chapter.php?id=2002"], "Semantic IDs and ascending directory")
        let pages = try await adapter.pages(chapter: chapters[0], context: context)
        try expect(pages.count == 2 && pages[0].id.externalID == "1" && pages[1].ordinal == 1, "Guazi body and stable page numbers")
    },
    Check("GuaziAdapterTests.nextChapterIsNotPagePagination") {
        let source = BuiltinSources.candidates()[1]; let chapter = Samples.chapter(Samples.work(source))
        let html = try fixtureText("guazi-chapter") + "<a data-reader-next href='/chapter.php?id=2002'>下一章</a>"
        let client = FixtureHTTPClient([chapter.url.absoluteString: textResponse(html, chapter.url)])
        let pages = try await GuaziAdapter().pages(chapter: chapter, context: ParserContext(source: source, client: client))
        let count = await client.requests.count
        try expect(pages.count == 2 && count == 1, "Next chapter must not be appended to this chapter")
    },
    Check("GuaziAdapterTests.guaziCDNRestrictionReported") {
        let source = BuiltinSources.candidates()[1]; let url = URL(string: "https://www.guazimanhua.com/comic.php?id=100")!
        let chapterURL = URL(string: "https://www.guazimanhua.com/chapter.php?id=2001")!
        let imageURL = URL(string: "https://img.guazicdn.com/th/comics/chapters/sample/1_1.webp")!
        let client = FixtureHTTPClient([url.absoluteString: textResponse(try fixtureText("guazi-detail"), url), chapterURL.absoluteString: textResponse(try fixtureText("guazi-chapter"), chapterURL), imageURL.absoluteString: ResourceResponse(data: Data(), finalURL: imageURL, statusCode: 403)])
        let report = await SourceDetector(registry: ParserRegistry(adapters: [GuaziAdapter()]), client: client, verifier: ImageVerifier()).detect(source: source, samples: [url])
        try expect(report.status == .accessFailure, "Image restriction cannot be presented as readable")
    },
    Check("GuaziAdapterTests.browseAndSearchCapabilitiesAreIndependent") {
        try expect(BuiltinSources.candidates().allSatisfy { $0.capabilities.isEmpty && $0.binding == nil }, "Candidates are unverified")
        let source = BuiltinSources.candidates()[1]
        let homepage = "<a href='/comic.php?id=1'><h3>漫画甲</h3></a>"
        let searchURL = URL(string: "https://www.guazimanhua.com/category.php?keyword=%E6%BC%AB%E7%94%BB")!
        let client = FixtureHTTPClient([source.baseURL.absoluteString: textResponse(homepage, source.baseURL), searchURL.absoluteString: textResponse(homepage, searchURL)])
        let adapter = GuaziAdapter(); let context = ParserContext(source: source, client: client)
        let browse = try await adapter.browse(context: context); let search = try await adapter.search(query: "漫画", context: context)
        try expect(browse.count == 1 && search.count == 1, "Browse and public search are independent operations")
    }
]
