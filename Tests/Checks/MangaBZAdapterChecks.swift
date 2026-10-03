import Foundation
import MangaCore
private let bzSource = Source(name: "MangaBZ", baseURL: URL(string: "https://www.mangabz.com/")!)
private let bzWorkURL = bzSource.baseURL.appendingPathComponent("38bz/")
private let bzDetail = "<p class='detail-info-title'>样本</p><img class='detail-info-cover' src='https://cover.test/a.jpg'><div id='chapterlistload'><a href='/m102/'>第二话</a><a href='/m101/'>第一话</a><a href='https://other.test/m1/'>陷阱</a></div>"
private actor BZFixtureClient: HTTPClient {
    var signature = "old"
    let paired:Bool
    var imageCalls=0
    init(paired:Bool=false){self.paired=paired}
    func calls() -> Int {imageCalls}
    func refresh() { signature = "new" }
    func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        if request.url.lastPathComponent == "chapterimage.ashx" {
            imageCalls += 1
            let page = URLComponents(url:request.url,resolvingAgainstBaseURL:false)!.queryItems!.first{$0.name == "page"}!.value!
            let files=paired ? "'p\(page).jpg','p\(Int(page)!+1).jpg'" : "'p\(page).jpg'"
            return textResponse("function dm5imagefun(){var pix='https://images.test/';var pvalue=[\(files)];pvalue[i]=pix+pvalue[i]+'?sign=\(signature)';return pvalue}var d=dm5imagefun();",request.url)
        }
        return textResponse("<script>var MANGABZ_CID=101;var MANGABZ_MID=38;var MANGABZ_IMAGE_COUNT=2;var MANGABZ_VIEWSIGN_DT='date';var MANGABZ_VIEWSIGN='sign';var isVip='False';</script>",request.url)
    }
}
public let mangaBZAdapterChecks:[Check] = [
    Check("MangaBZAdapterTests.listingFindsCoverBesideTitleLink") {
        guard let adapter=BuiltinSources.candidateAdapter(for:bzSource) else {throw CheckFailure(description:"Missing adapter")}
        let html="<div class='index-manga-item'><a href='/38bz/'><img src='https://cover.test/38.jpg'></a><p class='index-manga-item-title'><a href='/38bz/'>样本</a></p></div>"
        let works=try await adapter.browse(context:ParserContext(source:bzSource,client:FixtureHTTPClient([bzSource.baseURL.absoluteString:textResponse(html,bzSource.baseURL)])))
        try expect(works.count == 1 && works[0].title == "样本" && works[0].coverURL?.absoluteString == "https://cover.test/38.jpg","Resolve cover from the same listing item even when title and image are separate anchors")
    },
    Check("MangaBZAdapterTests.canonicalWorkIdentityForSlashAndTrackingVariants") {
        guard let adapter=BuiltinSources.candidateAdapter(for:bzSource) else {throw CheckFailure(description:"Missing adapter")}
        for variant in ["https://www.mangabz.com/38bz","https://www.mangabz.com/38bz/?from=bookmark"] {
            let url=URL(string:variant)!
            let ctx=ParserContext(source:bzSource,client:FixtureHTTPClient([url.absoluteString:textResponse(bzDetail,url),bzWorkURL.absoluteString:textResponse(bzDetail,bzWorkURL)]))
            let work=try await adapter.details(url:url,context:ctx)
            try expect(work.id.externalID == "/38bz/" && work.url == bzWorkURL,"Accepted work links canonicalize before creating persisted identity")
        }
    },
    Check("MangaBZAdapterTests.readerPreloadPairAvoidsDuplicateRequests") {
        guard let adapter=BuiltinSources.candidateAdapter(for:bzSource) else {throw CheckFailure(description:"Missing MangaBZ adapter")}
        let work=SourceWork(id:SourceWorkID(sourceID:bzSource.id,externalID:"/38bz/"),title:"样本",url:bzWorkURL)
        let chapter=Chapter(id:ChapterID(sourceWorkID:work.id,externalID:"/m101/"),title:"第一话",url:bzSource.baseURL.appendingPathComponent("m101/"),ordinal:0)
        let client=BZFixtureClient(paired:true)
        let pages=try await adapter.pages(chapter:chapter,context:ParserContext(source:bzSource,client:client))
        let calls=await client.calls()
        try expect(pages.map{$0.request.url.lastPathComponent} == ["p1.jpg","p2.jpg"] && calls == 1,"Reuse the reader's next-image preload instead of requesting its address twice")
    },
    Check("MangaBZAdapterTests.completeDirectoryAndScopedLinks") {
        guard let adapter = BuiltinSources.candidateAdapter(for:bzSource) else { throw CheckFailure(description:"Missing MangaBZ adapter") }
        let ctx=ParserContext(source:bzSource,client:FixtureHTTPClient([bzWorkURL.absoluteString:textResponse(bzDetail,bzWorkURL)]))
        let work=try await adapter.details(url:bzWorkURL,context:ctx);let chapters=try await adapter.chapters(work:work,context:ctx)
        try expect(work.title == "样本" && chapters.map(\.title) == ["第一话","第二话"],"Complete chronological chapters excluding foreign URL")
    },
    Check("MangaBZAdapterTests.signedResourcesRefreshKeepIdentity") {
        guard let adapter=BuiltinSources.candidateAdapter(for:bzSource) else {throw CheckFailure(description:"Missing MangaBZ adapter")}
        let work=SourceWork(id:SourceWorkID(sourceID:bzSource.id,externalID:"/38bz/"),title:"样本",url:bzWorkURL)
        let chapter=Chapter(id:ChapterID(sourceWorkID:work.id,externalID:"/m101/"),title:"第一话",url:bzSource.baseURL.appendingPathComponent("m101/"),ordinal:0)
        let client=BZFixtureClient();let ctx=ParserContext(source:bzSource,client:client)
        let old=try await adapter.pages(chapter:chapter,context:ctx);await client.refresh();let new=try await adapter.pages(chapter:chapter,context:ctx)
        try expect(old.map(\.ordinal) == [0,1] && old.map(\.id) == new.map(\.id) && old[0].request.url != new[0].request.url,"Ordered actual images with stable IDs when signed URL refreshes")
        var paid=chapter;paid.access = .paid
        do {_ = try await adapter.pages(chapter:paid,context:ctx);throw CheckFailure(description:"Paid content must stay blocked")}catch MangaError.chapterUnavailable {}
    }
]
