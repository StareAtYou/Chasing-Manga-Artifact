import Foundation
import MangaCore
import MangaPlatform
private let recommendationHome = """
<nav><a href='/history/'>历史</a><a href='/manga-list-31-0-0/'>熱血</a><a href='/manga-list-26-0-0/'>戀愛</a><a href='https://elsewhere.invalid/manga-list-2-0-0/'>冒险</a></nav>
<section><p class='list-con-title'>熱度排行</p><div><a href='/2bz/' title='热门乙'></a><a href='/1bz/' title='热门甲'></a><a href='/2bz/' title='热门乙'></a></div></section>
<section><p class='list-con-title'>最新更新</p><a href='/3bz/' title='更新丙'></a></section>
"""
private func recommendationFixture(_ root:URL,client:(any HTTPClient)?=nil) async throws -> (SourceService,LibraryStore,Source) {
    var source=BuiltinSources.candidates()[6];source.binding=ParserBinding(parserID:"mangabz-reader")
    let store=try LibraryStore(databaseURL:root.appendingPathComponent("library.sqlite"));try await store.save(source:source)
    let service=SourceService(store:store,registry:ParserRegistry(adapters:[MangaBZAdapter()]),client:client ?? FixtureHTTPClient([source.baseURL.absoluteString:textResponse(recommendationHome,source.baseURL)]),verifier:ImageVerifier())
    return (service,store,source)
}
private actor GatedRecommendationClient:HTTPClient {
    var entered=false
    var gate:CheckedContinuation<Void,Never>?
    func send(_ request:ResourceRequest,sourceID:SourceID,priority:RequestPriority) async throws -> ResourceResponse {
        entered=true;await withCheckedContinuation {gate=$0}
        return textResponse(recommendationHome,request.url)
    }
    func release() {gate?.resume();gate=nil}
}
private struct DexRecommendationClient:HTTPClient {
    func send(_ request:ResourceRequest,sourceID:SourceID,priority:RequestPriority) async throws -> ResourceResponse {
        guard request.url.host=="api.mangadex.org" else {throw MangaError.invalidURL}
        let body:String
        if request.url.path=="/manga/tag" {body = #"{"result":"ok","data":[{"id":"00000000-0000-0000-0000-000000000031","attributes":{"name":{"en":"Adventure"},"group":"genre"}},{"id":"00000000-0000-0000-0000-000000000032","attributes":{"name":{"en":"Full Color"},"group":"format"}}]}"#}
        else {
            let items=URLComponents(url:request.url,resolvingAgainstBaseURL:false)?.queryItems ?? []
            let isPopular=items.contains{$0.name=="order[followedCount]" && $0.value=="desc"}
            let title=isPopular ? "关注示例" : "更新示例"
            body = "{\"result\":\"ok\",\"total\":1,\"data\":[{\"id\":\"00000000-0000-0000-0000-000000000041\",\"attributes\":{\"title\":{\"zh\":\""+title+"\"},\"description\":{}},\"relationships\":[]}]}"
        }
        return textResponse(body,request.url)
    }
}
private struct ReadOnlyRecommendationAdapter:SourceAdapter {
    let id="readonly-recommendation-fixture";let version=1;let capabilities:SourceCapabilities = [.readable]
    func details(url:URL,context:ParserContext) async throws -> SourceWork {Samples.work(context.source)}
    func chapters(work:SourceWork,context:ParserContext) async throws -> [Chapter] {[Samples.chapter(work)]}
    func pages(chapter:Chapter,context:ParserContext) async throws -> [PageResource] {Samples.pages(chapter)}
}
public let catalogRecommendationChecks:[Check] = [
    Check("CatalogRecommendationTests.realTaxonomyAndScopedPopularOrdering") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let (service,_,source)=try await recommendationFixture(root)
        let result=try await service.recommendations(sourceID:source.id)
        try expect(result.channels.filter{$0.kind == .genre}.map(\.genre)==["热血","恋爱"],"Normalize genuine source taxonomy and reject external category links")
        let rank=result.sections.first{$0.channel.kind == .popular}
        try expect(rank?.works.map(\.title)==["热门乙","热门甲"],"Preserve source ranking order, deduplicate and exclude latest-update siblings")
        let cached=try await service.cachedRecommendations(sourceID:source.id)
        try expect(cached?.sections.first{$0.channel.kind == .popular}?.works.map(\.title)==["热门乙","热门甲"],"Successful source recommendations survive reopening")
    },
    Check("CatalogRecommendationTests.categoryPaginationAndUntrustedURLRejection") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let source=BuiltinSources.candidates()[6];let first=source.baseURL.appendingPathComponent("manga-list-31-0-0/");let next=source.baseURL.appendingPathComponent("manga-list-31-0-0-p2/")
        let client=FixtureHTTPClient([source.baseURL.absoluteString:textResponse(recommendationHome,source.baseURL),first.absoluteString:textResponse("<a href='/1bz/' title='分类甲'></a><a rel='next' href='/manga-list-31-0-0-p2/'>下一頁</a>",first),next.absoluteString:textResponse("<a href='/4bz/' title='分类丁'></a><a rel='next' href='https://bad.invalid/page/3'>下一页</a>",next)])
        let (service,_,saved)=try await recommendationFixture(root,client:client)
        let snapshot=try await service.recommendations(sourceID:saved.id)
        guard let genre=snapshot.channels.first(where:{$0.genre == "热血"}) else {throw CheckFailure(description:"Genuine genre channel was not discovered")}
        let page=try await service.catalogPage(sourceID:saved.id,channelID:genre.id)
        try expect(page.works.map(\.title)==["分类甲"] && page.nextURL==next,"Load the actual genre page and expose its genuine next-page link")
        let more=try await service.catalogPage(sourceID:saved.id,channelID:genre.id,pageURL:next)
        try expect(more.works.map(\.title)==["分类丁"] && more.nextURL==nil,"Category pagination appends new items and ignores external navigation")
        do {_ = try await service.catalogPage(sourceID:saved.id,channelID:genre.id,pageURL:URL(string:"https://bad.invalid/")!);throw CheckFailure(description:"Untrusted page accepted")} catch MangaError.invalidURL {}
        do {_ = try await service.catalogPage(sourceID:saved.id,channelID:genre.id,pageURL:source.baseURL.appendingPathComponent("manga-list-26-0-0/"));throw CheckFailure(description:"Different category accepted")} catch MangaError.invalidURL {}
    },
    Check("CatalogRecommendationTests.changedSourceCannotPublishInFlightRecommendations") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let client=GatedRecommendationClient();let (service,store,source)=try await recommendationFixture(root,client:client)
        let pending=Task {try await service.recommendations(sourceID:source.id)}
        for _ in 0..<100_000 {if await client.entered {break};await Task.yield()}
        try await store.setSourceEnabled(false,id:source.id);await client.release()
        do {_ = try await pending.value;throw CheckFailure(description:"Disabled source published late content")} catch is CancellationError {}
        let saved=try await store.record(kind:"recommendation-cache",key:source.id.key,as:SourceRecommendations.self)
        try expect(saved==nil,"Stale source response cannot update the persistent cache")
    },
    Check("CatalogRecommendationTests.mangaDexGenreUsesActualPopularityOrder") {
        let source=BuiltinSources.candidates()[3];let context=ParserContext(source:source,client:DexRecommendationClient())
        let result=try await MangaDexAdapter().recommendations(context:context)
        let genres=result.channels.filter{$0.kind == .genre}
        try expect(genres.map(\.genre)==["冒险"],"MangaDex genre taxonomy excludes unrelated format tags")
        try expect(result.sections.first{$0.channel.kind == .popular}?.works.map(\.title)==["关注示例"],"Popular recommendations request followed-count order rather than recent-upload order")
        guard let genre=genres.first else {throw CheckFailure(description:"Missing API genre")}
        let page=try await MangaDexAdapter().catalogPage(channel:genre,sort:.popularity,pageURL:nil,context:context)
        try expect(page.works.map(\.title)==["关注示例"],"Genre popularity browsing uses the source's actual follow-count ranking")
    },
    Check("CatalogRecommendationTests.readOnlyCustomSourceShowsSavedWorksWithoutInventedRanks") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        var source=Samples.sourceA;source.binding=ParserBinding(parserID:"readonly-recommendation-fixture");source.capabilities = [.readable]
        let store=try LibraryStore(databaseURL:root.appendingPathComponent("db.sqlite"));try await store.save(source:source)
        let work=Samples.work(source);try await store.save(sourceWork:work,chapters:[Samples.chapter(work)])
        let service=SourceService(store:store,registry:ParserRegistry(adapters:[ReadOnlyRecommendationAdapter()]),client:FixtureHTTPClient([:]),verifier:ImageVerifier())
        let result=try await service.recommendations(sourceID:source.id)
        try expect(result.sections.flatMap(\.works).map(\.id)==[work.id] && result.channels.allSatisfy{$0.kind == .browse},"Reading-only custom sources retain saved works without fabricated genre or rank data")
        let page=try await service.catalogPage(sourceID:source.id,channelID:result.channels[0].id)
        try expect(page.works.map(\.id)==[work.id],"Saved-work browsing remains usable without a source catalogue")
    },
    Check("CatalogRecommendationTests.latestOnlyNeverBecomesPopular") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let source=BuiltinSources.candidates()[6]
        let client=FixtureHTTPClient([source.baseURL.absoluteString:textResponse("<section><p class='list-con-title'>最新更新</p><a href='/3bz/' title='更新丙'></a></section>",source.baseURL)])
        let (service,_,saved)=try await recommendationFixture(root,client:client)
        let result=try await service.recommendations(sourceID:saved.id)
        try expect(!result.sections.isEmpty && result.sections.allSatisfy{$0.channel.kind != .popular},"Sources without an evidenced popular section remain browse content")
    }
]
