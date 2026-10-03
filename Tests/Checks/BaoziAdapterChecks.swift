import Foundation
import MangaCore
import MangaPlatform
private let baozi = Source(name: "包子漫画", baseURL: URL(string: "https://baozimh.org/")!)
private let baoziURL = URL(string: "https://baozimh.org/manga/demo")!
private let baoziDetail = "<h1>原创样本 <span>连载中</span></h1><meta property='og:image' content='https://images.test/cover.webp'><meta name='description' content='简介'><a href='/manga-author/author'>作者</a><div id='mangachapters' data-mid='5'></div>"
public let baoziAdapterChecks: [Check] = [
    Check("BaoziAdapterTests.fractionalChapterOrderPreservesInterleavedChapters") {
        let endpoint = URL(string: "https://v2.apikk.top/api/manga/get?mid=5&mode=all")!
        // The public catalogue interleaves extra chapters using fractional order.
        let json = #"{"code":200,"status":true,"data":{"id":"5","slug":"demo","chapters":[{"id":"last","attributes":{"title":"第三话","slug":"5-3","order":2}},{"id":"extra2","attributes":{"title":"番外乙","slug":"5-extra-b","order":1.2}},{"id":"first","attributes":{"title":"第一话","slug":"0_0","order":0}},{"id":"extra1","attributes":{"title":"番外甲","slug":"5-extra-a","order":1.1}},{"id":"middle","attributes":{"title":"第二话","slug":"5-2","order":1}}]}}"#
        let client = FixtureHTTPClient([baoziURL.absoluteString: textResponse(baoziDetail, baoziURL), endpoint.absoluteString: textResponse(json, endpoint)])
        let context = ParserContext(source: baozi, client: client)
        let work = try await BaoziAdapter().details(url: baoziURL, context: context)
        let chapters = try await BaoziAdapter().chapters(work: work, context: context)
        try expect(chapters.map(\.title) == ["第一话", "第二话", "番外甲", "番外乙", "第三话"] && chapters.map(\.ordinal) == [0,1,2,3,4], "Fractional values must not invalidate the whole directory, truncate order, or drop extra chapters")
        try expect(chapters.map { $0.url.lastPathComponent } == ["0_0", "5-2", "5-extra-a", "5-extra-b", "5-3"], "Preserve original chapter URLs for reading and full-work downloads")
    },
    Check("BaoziAdapterTests.removedWorkDoesNotInvalidateSourceBinding") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
        var source = baozi; source.binding = ParserBinding(parserID: BaoziAdapter().id)
        try await store.save(source: source)
        let html = "<h1>原创样本 <span>章節下架</span></h1><p>章節已下架</p><a href='https://other.test/reader'>前往源站</a>"
        let client = FixtureHTTPClient([baoziURL.absoluteString: textResponse(html, baoziURL)])
        let service = SourceService(store: store, registry: ParserRegistry(adapters: [BaoziAdapter()]), client: client, verifier: ImageVerifier())
        for _ in 0..<2 {
            do { _ = try await service.loadWork(url: baoziURL, sourceID: source.id); throw CheckFailure(description: "Removed chapters cannot be opened") }
            catch let error as MangaError { try expect(error.localizedDescription.contains("下架") && error.localizedDescription.contains("其他"), "Explain the original site's removal and suggest another source, instead of a parser mismatch") }
        }
        let saved = try await store.source(id: source.id)
        try expect(saved?.binding?.structureFailures == 0 && saved?.binding?.needsRetest == false, "One unavailable work must not disable the source's parser")
        try expect(await client.requests.allSatisfy { $0.url.host == "baozimh.org" }, "Do not silently follow a removed work into a different source")
    },
    Check("BaoziAdapterTests.removedCachedWorkReportsAvailabilityBeforeMissingDirectory") {
        let html = "<h1>原创样本 <span>章节下架</span></h1><p>章节已下架</p>"
        let work = SourceWork(id: SourceWorkID(sourceID: baozi.id, externalID: "/manga/demo"), title: "原创样本", url: baoziURL)
        do {
            _ = try await BaoziAdapter().chapters(work: work, context: ParserContext(source: baozi, client: FixtureHTTPClient([baoziURL.absoluteString: textResponse(html, baoziURL)])))
            throw CheckFailure(description: "Removed directory must be unavailable")
        } catch let error as MangaError { try expect(error.localizedDescription.contains("下架"), "Saved works receive an availability error, not a missing mid mismatch") }
    },
    Check("BaoziAdapterTests.removedReaderReportsAvailabilityBeforeMissingImages") {
        let work = SourceWork(id: SourceWorkID(sourceID: baozi.id, externalID: "/manga/demo"), title: "原创样本", url: baoziURL)
        let chapter = Chapter(id: ChapterID(sourceWorkID: work.id, externalID: "/manga/demo/5-1-1"), title: "第一话", url: baoziURL.appendingPathComponent("5-1-1"), ordinal: 0)
        let html = "<h1>原创样本 <span>章節下架</span></h1><p>章節已下架</p>"
        let renderer = FixturePageRenderer(page: RenderedPage(url: chapter.url, html: html, accessContextID: UUID()))
        do {
            _ = try await BaoziAdapter().pages(chapter: chapter, context: ParserContext(source: baozi, client: FixtureHTTPClient([:]), renderer: renderer))
            throw CheckFailure(description: "Removed reader must be unavailable")
        } catch let error as MangaError { try expect(error.localizedDescription.contains("下架"), "Reader removal is distinct from an image parser failure") }
    },
    Check("BaoziAdapterTests.completeOrderedChapterList") {
        guard let adapter = BuiltinSources.candidateAdapter(for:baozi) else { throw CheckFailure(description:"Missing Baozi adapter") }
        let endpoint = URL(string:"https://v2.apikk.top/api/manga/get?mid=5&mode=all")!
        let json = #"{"code":200,"status":true,"data":{"id":"5","slug":"demo","chapters":[{"id":"last","attributes":{"title":"第三话","slug":"5-3-3","order":3}},{"id":"first","attributes":{"title":"第一话","slug":"5-1-1","order":1}},{"id":"middle","attributes":{"title":"第二话","slug":"5-2-2","order":2}}]}}"#
        let ctx = ParserContext(source:baozi,client:FixtureHTTPClient([baoziURL.absoluteString:textResponse(baoziDetail,baoziURL),endpoint.absoluteString:textResponse(json,endpoint)]))
        let work = try await adapter.details(url:baoziURL,context:ctx);let chapters = try await adapter.chapters(work:work,context:ctx)
        try expect(work.title == "原创样本" && work.author == "作者" && chapters.map(\.title) == ["第一话","第二话","第三话"],"Use complete API catalogue, sorted chronologically without status badge in title")
    },
    Check("BaoziAdapterTests.renderedPagesExcludeAdsAndKeepLazyImages") {
        guard let adapter = BuiltinSources.candidateAdapter(for:baozi) else { throw CheckFailure(description:"Missing Baozi adapter") }
        let work = SourceWork(id:SourceWorkID(sourceID:baozi.id,externalID:"/manga/demo"),title:"原创样本",url:baoziURL);let chapter = Chapter(id:ChapterID(sourceWorkID:work.id,externalID:"/manga/demo/5-1-1"),title:"第一话",url:baoziURL.appendingPathComponent("5-1-1"),ordinal:0)
        let id = UUID();let html = "<img src='https://ads.test/banner.png'><div id='chapcontent'><img src='data:image/gif;base64,sample' data-src='https://images.test/1.webp'><img data-src='https://images.test/2.webp'></div>"
        let renderer = FixturePageRenderer(page:RenderedPage(url:chapter.url,html:html,accessContextID:id))
        let pages = try await adapter.pages(chapter:chapter,context:ParserContext(source:baozi,client:FixtureHTTPClient([:]),renderer:renderer))
        try expect(pages.count == 2 && pages.map{$0.request.url.lastPathComponent} == ["1.webp","2.webp"] && pages[0].request.accessContextID == id,"Only reader images; retain unloaded image URLs and scoped context")
    }
]
