import Foundation
import MangaCore
private let baozi = Source(name: "包子漫画", baseURL: URL(string: "https://baozimh.org/")!)
private let baoziURL = URL(string: "https://baozimh.org/manga/demo")!
private let baoziDetail = "<h1>原创样本 <span>连载中</span></h1><meta property='og:image' content='https://images.test/cover.webp'><meta name='description' content='简介'><a href='/manga-author/author'>作者</a><div id='mangachapters' data-mid='5'></div>"
public let baoziAdapterChecks: [Check] = [
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
