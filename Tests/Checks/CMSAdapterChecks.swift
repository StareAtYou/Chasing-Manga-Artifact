import Foundation
import MangaCore
import MangaPlatform
private func cmsSource(_ host: String) -> Source { Source(name: host, baseURL: URL(string: "https://" + host + "/")!) }
private func cmsAdapter(_ source: Source) throws -> any SourceAdapter {
    guard let adapter = BuiltinSources.candidateAdapter(for: source) else { throw CheckFailure(description: "Requested CMS source has no registered adapter") }; return adapter
}
private struct CMSHeadersRequiredClient: HTTPClient {
    let client: any HTTPClient
    func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        guard request.headers["User-Agent"] == "Mozilla/5.0", request.headers["Accept"]?.contains("text/html") == true, request.referer != nil else { throw MangaError.accessRestricted(403) }
        return try await client.send(request, sourceID: sourceID, priority: priority)
    }
}
private let duokanHome = """
<div><h3>国漫周榜</h3><div class='comic-item'><div class='comic-cover lazy' data-original='https://images.test/cover.webp'><a class='thumb-link' href='/manhua/hero'></a></div><h4 class='title'><a href='/manhua/hero' title='测试漫画'>测试漫画</a></h4></div></div>
<a href='/fenlei/area/guoman'>国产漫画</a><a href='/fenlei/theme/rexue'>热血</a><a href='/fenlei/theme/bad'>第107话 蜘蛛</a><a href='/fenlei/page/2'>下一页</a><a href='https://other.test/manhua/ad'>广告</a>
"""
private let duokanWork = """
<div class='comic-cover-box'><img class='comic-cover' data-original='https://images.test/cover.webp'></div><div class='comic-detail'><h1 class='title'><span>测试漫画</span><span class='score'>9.9</span></h1><p class='data'><span>类型：热血</span></p><p class='data'><span>作者：测试作者</span></p><p class='desc'>简介：测试简介</p></div>
<ul class='chapter-list'><li><a href='/manhua/hero/1.html'>第1话</a></li><li><a href='/manhua/hero/2.html'>第2话</a></li><li><a href='/manhua/hero/1.html'>重复</a></li><li><a href='https://other.test/manhua/hero/3.html'>广告</a></li></ul>
"""
private let fengcheHome = """
<div><h2>热门推荐</h2><li class='swiper-slide'><div class='pic'><a href='/comic/hero' title='测试漫画'><div class='img-wrapper' data-original='http://www.fengchemh.com/cover.webp'></div></a></div><div><h3><a href='/comic/hero'>测试漫画</a></h3></div></li></div><a href='/category/list/1'>国产漫画</a><a href='/category/tags/12'>热血</a><a href='/custom/top'>排行榜</a>
"""
private let fengcheWork = """
<div class='vod-info'><div class='img-wrapper' data-original='http://www.fengchemh.com/cover.webp'></div><div class='info'><h1><a href='/comic/hero'>测试漫画</a></h1><p><span>作者：测试作者</span></p><div class='desc'>测试简介</div></div></div><ul class='ewave-playlist-content'><li><a href='/chapter/one.html'>第1话</a></li><li><a href='/chapter/two.html'>第2话</a></li><li><a href='/chapter/one.html'>重复</a></li></ul>
"""
private func cmsChapter(_ source: Source, duokan: Bool) -> Chapter {
    let work = SourceWorkID(sourceID: source.id, externalID: duokan ? "/manhua/hero" : "/comic/hero")
    let path = duokan ? "/manhua/hero/1.html" : "/chapter/one.html"
    return Chapter(id: ChapterID(sourceWorkID: work, externalID: path), title: "第1话", url: source.baseURL.appendingPathComponent(String(path.dropFirst())), ordinal: 0)
}
private func cmsPageContext(_ source: Source, _ fixture: String, duokan: Bool) throws -> ParserContext {
    let chapter = cmsChapter(source, duokan: duokan)
    return ParserContext(source: source, client: FixtureHTTPClient([chapter.url.absoluteString: textResponse(try fixtureText(fixture), chapter.url)]))
}
public let cmsAdapterChecks: [Check] = [
    Check("CMSSourceTests.builtinsAppendBothWithoutChangingExistingIdentities") {
        let all = BuiltinSources.candidates()
        try expect(all.count == 14 && all[9].baseURL.host == "www.duokanmh.com" && all[10].baseURL.host == "www.fengchemh.com", "Both requested sources must be appended")
        for index in 0..<9 { try expect(all[index].id.rawValue == UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012d", 100 + index)), "Existing source identities must not move") }
    },
    Check("CMSSourceTests.listingsKeepCoversTitlesAndScope") {
        for (host, html) in [("www.duokanmh.com",duokanHome),("www.fengchemh.com",fengcheHome)] {
            let source = cmsSource(host); let adapter = try cmsAdapter(source)
            let works = try await adapter.browse(context: ParserContext(source: source, client: FixtureHTTPClient([source.baseURL.absoluteString:textResponse(html,source.baseURL)])))
            try expect(works.count == 1 && works[0].title == "测试漫画" && works[0].coverURL?.scheme == "https", "Merge thumbnail/title duplicates and retain lazy covers without offsite advertisements")
        }
    },
    Check("CMSSourceTests.detailsAndCompleteChapterOrder") {
        for (host, html, path) in [("www.duokanmh.com",duokanWork,"manhua/hero"),("www.fengchemh.com",fengcheWork,"comic/hero")] {
            let source = cmsSource(host); let adapter = try cmsAdapter(source); let url = source.baseURL.appendingPathComponent(path)
            let context = ParserContext(source:source,client:FixtureHTTPClient([url.absoluteString:textResponse("<img src='/logo.png'>" + html,url)]))
            let work = try await adapter.details(url:url,context:context);let chapters = try await adapter.chapters(work:work,context:context)
            try expect(work.title == "测试漫画" && work.author == "测试作者" && work.summary == "测试简介", "Score and labels must not pollute metadata")
            try expect(work.coverURL?.lastPathComponent == "cover.webp", "The site logo must not replace the work cover")
            try expect(chapters.map(\.title) == ["第1话","第2话"] && chapters.map(\.ordinal) == [0,1], "Keep the complete ascending chapter list, deduplicate and reject offsite links")
        }
    },
    Check("CMSSourceTests.duokanDecodesNativeReaderAndUsesSiteImageRoute") {
        let source = cmsSource("www.duokanmh.com");let chapter = cmsChapter(source,duokan:true)
        let pages = try await cmsAdapter(source).pages(chapter:chapter,context:cmsPageContext(source,"duokan-cms-reader",duokan:true))
        try expect(pages.count == 2 && pages.map(\.id.externalID) == ["1","2"], "Decode the entire image list using stable ordinal page IDs")
        try expect(pages[0].request.url.absoluteString == "https://images.test/" + Data("https://origin.test/1.webp".utf8).base64EncodedString() && pages[0].request.referer == chapter.url, "Use the site's actual image host and encoding route")
    },
    Check("CMSSourceTests.fengcheDecodesNativeReader") {
        let source = cmsSource("www.fengchemh.com");let chapter = cmsChapter(source,duokan:false)
        let pages = try await cmsAdapter(source).pages(chapter:chapter,context:cmsPageContext(source,"fengche-cms-reader",duokan:false))
        try expect(pages.count == 2 && pages.map(\.id.externalID) == ["1","2"] && pages[0].request.url.absoluteString == "https://images.test/1.webp", "Decode actual Fengche image URLs without DOM/browser image waits")
    },
    Check("CMSSourceTests.rejectsWrongChapterWrongHostDownAndMalformedPayload") {
        for (host,fixture,duokan) in [("www.duokanmh.com","duokan-cms-wrong-chapter",true),("www.fengchemh.com","fengche-cms-wrong-host",false),("www.fengchemh.com","fengche-cms-invalid-image",false)] {
            let source=cmsSource(host)
            do {_ = try await cmsAdapter(source).pages(chapter:cmsChapter(source,duokan:duokan),context:cmsPageContext(source,fixture,duokan:duokan));throw CheckFailure(description:"Unrelated or incomplete reader data accepted")} catch MangaError.parseMismatch { }
        }
        let source=cmsSource("www.duokanmh.com")
        do {_ = try await cmsAdapter(source).pages(chapter:cmsChapter(source,duokan:true),context:cmsPageContext(source,"duokan-cms-down",duokan:true));throw CheckFailure(description:"Removed work accepted")} catch MangaError.workUnavailable { }
        let chapter=cmsChapter(source,duokan:true)
        do {_ = try await cmsAdapter(source).pages(chapter:chapter,context:ParserContext(source:source,client:FixtureHTTPClient([chapter.url.absoluteString:textResponse("<script>var params='%%%';</script>",chapter.url)])));throw CheckFailure(description:"Corrupt payload accepted")} catch MangaError.parseMismatch { }
    },
    Check("CMSSourceTests.searchEncodesQueriesAndKeepsVerificationExplicit") {
        let source=cmsSource("www.duokanmh.com");let query="测试 &+";var components=URLComponents(url:source.baseURL.appendingPathComponent("search"),resolvingAgainstBaseURL:false)!;components.queryItems=[URLQueryItem(name:"q",value:query)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B")
        let url=components.url!;let results=try await cmsAdapter(source).search(query:query,context:ParserContext(source:source,client:FixtureHTTPClient([url.absoluteString:textResponse(duokanHome,url)])))
        try expect(results.count==1,"Search parameters must remain one correctly encoded query")
        let feng=cmsSource("www.fengchemh.com");let search=feng.baseURL.appendingPathComponent("search").appending(queryItems:[URLQueryItem(name:"key",value:"测试")])
        let context=ParserContext(source:feng,client:FixtureHTTPClient([search.absoluteString:textResponse("<title>安全验证 - 风车漫画</title>",search)]))
        do {_ = try await cmsAdapter(feng).search(query:"测试",context:context);throw CheckFailure(description:"Challenge cannot be an empty successful search")} catch MangaError.verificationRequired { }
        let browser=FixturePageRenderer(page:RenderedPage(url:search,html:fengcheHome))
        let verified=try await cmsAdapter(feng).search(query:"测试",context:ParserContext(source:feng,client:context.client,renderer:browser))
        try expect(verified.count==1,"A source browser session after user verification can resume search")
    },
    Check("CMSSourceTests.duokanRecommendationsIncludeGuomanAndDetailedGenres") {
        let source=cmsSource("www.duokanmh.com");let area=source.baseURL.appendingPathComponent("fenlei/area/guoman")
        let context=ParserContext(source:source,client:CMSHeadersRequiredClient(client:FixtureHTTPClient([source.baseURL.absoluteString:textResponse(duokanHome,source.baseURL),area.absoluteString:textResponse(duokanHome,area)])))
        let result=try await cmsAdapter(source).recommendations(context:context)
        try expect(result.channels.contains{$0.url==area} && result.channels.contains{$0.genre=="热血"},"Keep the requested Guoman entrance and its detailed categories")
        try expect(result.sections.contains { $0.channel.kind == .popular && $0.channel.title == "国漫周榜" }, "Weekly charts must retain their source ranking label")
        try expect(!result.channels.contains{$0.title.contains("107话") || $0.title=="下一页"},"Malformed category labels and paging controls must not become genres")
    },
    Check("CMSSourceTests.fengcheNavigationArrowsAreNotGenres") {
        let source=cmsSource("www.fengchemh.com");let category=source.baseURL.appendingPathComponent("category/list/1")
        let html=fengcheHome+"<a href='/category/list/1'>更多&gt;</a>"
        let context=ParserContext(source:source,client:FixtureHTTPClient([source.baseURL.absoluteString:textResponse(html,source.baseURL),category.absoluteString:textResponse(html,category)]))
        let result=try await cmsAdapter(source).recommendations(context:context)
        try expect(result.channels.contains{$0.genre=="国漫"} && result.channels.contains{$0.genre=="热血"},"Region/category navigation must survive repeated More links to the same URL")
        try expect(!result.channels.contains{$0.genre?.contains("更多")==true},"Arrow-decorated navigation labels are not categories")
    },
    Check("CMSSourceTests.boundBuiltinSearchSurvivesFailedProbe") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = BuiltinSources.candidates().first { $0.baseURL.host == "www.fengchemh.com" }!
        let work = source.baseURL.appendingPathComponent("comic/hero"); let first = source.baseURL.appendingPathComponent("chapter/one.html"); let last = source.baseURL.appendingPathComponent("chapter/two.html")
        let image = URL(string: "https://images.test/2.webp")!; let encrypted = URL(string: "https://img1.baipiaoguai.org/book/content/1.bin")!; let vector = try cmsImageVector()
        let client = FixtureHTTPClient([source.baseURL.absoluteString: textResponse(fengcheHome, source.baseURL), work.absoluteString: textResponse(fengcheWork, work), first.absoluteString: textResponse(try fixtureText("fengche-cms-encrypted"), first), last.absoluteString: textResponse(try fixtureText("fengche-cms-encrypted"), last), encrypted.absoluteString: ResourceResponse(data: vector.cipher, finalURL: encrypted, statusCode: 200), image.absoluteString: ResourceResponse(data: vector.plain, finalURL: image, statusCode: 200)])
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("db.sqlite")); try await store.save(source: source)
        let service = SourceService(store: store, registry: ParserRegistry(adapters: [CMSMangaAdapter(site: .fengche)]), client: client, verifier: ImageVerifier())
        let report = try await service.retest(sourceID: source.id, samples: [work])
        try expect(report.binding?.parserID == "fengche-cms", "Real source detection must commit its valid reader binding")
        let inspection = try await service.inspectCatalog(sourceID: source.id)
        let latest = try await store.source(id: source.id)!
        try expect(inspection.errors["search"] != nil && !latest.capabilities.contains(.search), "Reproduce a bound reader with a failed search probe")
        try expect(SearchScope.source(source.id).sourceIDs(in: [latest]) == [source.id], "Known built-in search remains selectable after successful binding and a failed probe")
    },
    Check("CMSSourceTests.customSourceDetectionValidatesEncodedImages") {
        let source=cmsSource("www.fengchemh.com");let work=source.baseURL.appendingPathComponent("comic/hero");let first=source.baseURL.appendingPathComponent("chapter/one.html");let last=source.baseURL.appendingPathComponent("chapter/two.html");let encrypted=URL(string:"https://img1.baipiaoguai.org/book/content/1.bin")!;let direct=URL(string:"https://images.test/2.webp")!;let vector=try cmsImageVector()
        let client=FixtureHTTPClient([source.baseURL.absoluteString:textResponse(fengcheHome,source.baseURL),work.absoluteString:textResponse(fengcheWork,work),first.absoluteString:textResponse(try fixtureText("fengche-cms-encrypted"),first),last.absoluteString:textResponse(try fixtureText("fengche-cms-encrypted"),last),encrypted.absoluteString:ResourceResponse(data:vector.cipher,finalURL:encrypted,statusCode:200),direct.absoluteString:ResourceResponse(data:vector.plain,finalURL:direct,statusCode:200)])
        let report=await SourceDetector(registry:ParserRegistry(adapters:[try cmsAdapter(source)]),client:client,verifier:ImageVerifier()).detect(source:source,samples:[work])
        try expect(report.status == .limited && report.binding?.parserID == "fengche-cms", "Custom source detection must decode its representative images before validating and binding")
    },
    Check("CMSSourceTests.fengcheKeepsDeclaredImageRelay") {
        let source=cmsSource("www.fengchemh.com");let pages=try await cmsAdapter(source).pages(chapter:cmsChapter(source,duokan:false),context:cmsPageContext(source,"fengche-cms-relay",duokan:false))
        try expect(pages[0].request.url.host=="s2.325784.xyz","The declared relay is required; its embedded URL may return a hotlink-denial image instead of the comic")
    },
    Check("CMSSourceTests.fengcheEncryptedImagesCarryExplicitEncoding") {
        let source=cmsSource("www.fengchemh.com");let pages=try await cmsAdapter(source).pages(chapter:cmsChapter(source,duokan:false),context:cmsPageContext(source,"fengche-cms-encrypted",duokan:false))
        let first=try JSONSerialization.jsonObject(with:JSONEncoder().encode(pages[0].request)) as! [String:Any]
        try expect(first["imageEncoding"] as? String == "fengche-aes-v1" && pages[0].request.referer == nil && pages[0].request.url.host=="img1.baipiaoguai.org", "Mark only the site's relative encrypted-image transport and honor its no-referrer request")
        let second=try JSONSerialization.jsonObject(with:JSONEncoder().encode(pages[1].request)) as! [String:Any]
        try expect(second["imageEncoding"]==nil,"Ordinary direct images must remain unchanged")
    }
]
func cmsImageVector() throws -> (plain: Data, cipher: Data) {
    let url = Bundle.module.url(forResource: "fengche-image-vector", withExtension: "json", subdirectory: "Fixtures")!
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String:String]
    return (Data(base64Encoded: json["png"]!)!, Data(base64Encoded: json["encrypted"]!)!)
}
func encodedCMSRequest(url: URL) throws -> ResourceRequest {
    var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ResourceRequest(url: url))) as! [String:Any]
    value["imageEncoding"] = "fengche-aes-v1"
    return try JSONDecoder().decode(ResourceRequest.self, from: JSONSerialization.data(withJSONObject: value))
}
public let cmsImageChecks: [Check] = [
    Check("CMSImageDecodeTests.pipelineCachesDecodedBytesAndRetainsRequestEncoding") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let vector = try cmsImageVector(); let url = URL(string:"https://img1.baipiaoguai.org/book/content/1.bin")!
        let request = try encodedCMSRequest(url:url); let chapter = Samples.chapter(Samples.work()); let page = PageResource(id:PageID(chapterID:chapter.id,externalID:"1"),ordinal:0,request:request)
        let pipeline = ImagePipeline(client:FixtureHTTPClient([url.absoluteString:ResourceResponse(data:vector.cipher,finalURL:url,statusCode:200)]),files:try PageFileStore(root:root))
        let file = try await pipeline.file(for:page,sourceID:Samples.sourceA.id)
        try expect(try Data(contentsOf:file)==vector.plain,"Image decoding must happen before verification and disk caching")
        let stored = try JSONSerialization.jsonObject(with:JSONEncoder().encode(request)) as! [String:Any]
        try expect(stored["imageEncoding"] as? String == "fengche-aes-v1","Persist the decoder for offline task restoration")
    },
    Check("CMSImageDecodeTests.invalidCipherDoesNotBecomeCachedImage") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url=URL(string:"https://img1.baipiaoguai.org/book/content/bad.bin")!;let chapter=Samples.chapter(Samples.work());let page=PageResource(id:PageID(chapterID:chapter.id,externalID:"1"),ordinal:0,request:try encodedCMSRequest(url:url))
        let files=try PageFileStore(root:root);let pipeline=ImagePipeline(client:FixtureHTTPClient([url.absoluteString:ResourceResponse(data:Data([1,2,3]),finalURL:url,statusCode:200)]),files:files)
        do {_ = try await pipeline.file(for:page,sourceID:Samples.sourceA.id);throw CheckFailure(description:"Invalid cipher cached")} catch MangaError.invalidImage { }
        try expect(await files.cachedFile(for:page.id)==nil,"Corrupt encoded resources must leave no valid cache entry")
    }
]
