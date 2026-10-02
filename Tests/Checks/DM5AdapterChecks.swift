import Foundation
import MangaCore
public actor DM5FixtureClient: HTTPClient {
    public var signature = "old"
    public init() { }
    public func updateSignature() { signature = "new" }
    public func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        if request.url.lastPathComponent == "chapterfun.ashx" {
            let page = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "page" }!.value!
            let script = "function dm5imagefun(){var cid=101;var key='';var pix='https://images.test/';var pvalue=['p\(page).jpg'];for(var i=0;i<pvalue.length;i++){if(/^(https?:)?\\/\\//i.test(pvalue[i])){continue}pvalue[i]=pix+pvalue[i]+'?sign=\(signature)'}return pvalue}var d;d=dm5imagefun();"
            return textResponse(script, request.url)
        }
        return textResponse(try fixtureText("dm5-reader"), request.url)
    }
}
public let dm5AdapterChecks: [Check] = [
    Check("DM5AdapterTests.dm5PageOrderAndCount") {
        let source = BuiltinSources.candidates()[2]; let chapter = Chapter(id: ChapterID(sourceWorkID: Samples.work(source).id, externalID: "/m101/"), title: "第1话", url: source.baseURL.appendingPathComponent("m101/"), ordinal: 0)
        let pages = try await DM5Adapter().pages(chapter: chapter, context: ParserContext(source: source, client: DM5FixtureClient()))
        try expect(pages.map(\.ordinal) == [0, 1] && pages.map { $0.request.url.lastPathComponent } == ["p1.jpg", "p2.jpg"], "Resolve complete ordered public reader pages")
    },
    Check("DM5AdapterTests.directoryPreservesChapterIdentity") {
        let source = BuiltinSources.candidates()[2]; let work = Samples.work(source)
        let client = FixtureHTTPClient([work.url.absoluteString: textResponse(try fixtureText("dm5-detail"), work.url)])
        let chapters = try await DM5Adapter().chapters(work: work, context: ParserContext(source: source, client: client))
        try expect(chapters.map { $0.id.externalID } == ["/m101/", "/m102/"], "Preserve site chapter IDs and reading order")
    },
    Check("DM5AdapterTests.expiredContextRefreshesWithoutChangingIdentity") {
        let source = BuiltinSources.candidates()[2]; let chapter = Samples.chapter(Samples.work(source)); let client = DM5FixtureClient()
        let adapter = DM5Adapter(); let context = ParserContext(source: source, client: client)
        let old = try await adapter.pages(chapter: chapter, context: context); await client.updateSignature()
        let new = try await adapter.pages(chapter: chapter, context: context)
        try expect(old.map(\.id) == new.map(\.id) && old[0].request.url != new[0].request.url, "Refreshing signed URLs preserves page identity")
    },
    Check("DM5AdapterTests.paidChapterStaysUnavailable") {
        let source = BuiltinSources.candidates()[2]; var chapter = Samples.chapter(Samples.work(source)); chapter.access = .paid
        do { _ = try await DM5Adapter().pages(chapter: chapter, context: ParserContext(source: source, client: DM5FixtureClient())); throw CheckFailure(description: "Paid chapter must remain unavailable") }
        catch MangaError.chapterUnavailable { }
    },
    Check("DM5AdapterTests.regionRestrictionIsAccessFailure") {
        let source = BuiltinSources.candidates()[2]; let url = source.baseURL.appendingPathComponent("manhua-sample/")
        let client = FixtureHTTPClient([url.absoluteString: textResponse("<p>您所在地区无法观看该漫画</p>", url)])
        do { _ = try await DM5Adapter().details(url: url, context: ParserContext(source: source, client: client)); throw CheckFailure(description: "Region restriction must remain blocked") }
        catch MangaError.regionRestricted { }
    },
    Check("DM5AdapterTests.packerExtractsDataWithoutExecutingCode") {
        let packed = "eval(function(p,a,c,k,e,d){return p}('0 1(){2 3=\\'https://images.test/\\';2 4=[\\'a.jpg\\'];4[i]=3+4[i]+\\'?sign=x\\';return 4}var d;d=1();',10,5,'function|dm5imagefun|var|pix|pvalue'.split('|'),0,{}))"
        let urls = try DM5ReaderData.urls(from: packed, base: URL(string: "https://www.dm5.com/m101/")!)
        try expect(urls.first?.lastPathComponent == "a.jpg", "Decode fixed literal template without eval")
        try expectError { _ = try DM5ReaderData.urls(from: "var d=fetchSecret();", base: Samples.sourceA.baseURL) }
    }
]
