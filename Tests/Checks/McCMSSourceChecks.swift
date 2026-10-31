import Foundation
import MangaCore

private func mcSource(_ host: String) -> Source { Source(name: "Fixture", baseURL: URL(string: "https://\(host)/")!) }
private func mcWorkPath(_ host: String) -> String { host == "www.77hh.net" ? "/comic-hero.html" : "/comic_hero.html" }
private func mcChapterPath(_ host: String, _ work: Int = 42, _ chapter: Int = 1) -> String { host == "www.77hh.net" ? "/chapter-\(work)-\(chapter).html" : "/chapter_\(work)_\(chapter).html" }
private func mcDetail(_ host: String) -> String {
    "<div class='comic-detail-section'><div class='comic-cover-large'><img src='https://images.test/cover.webp'></div><a class='j-user-collect' data-id='42'></a><div class='comic-meta-info'><h1>《测试作品》</h1><div class='comic-stats'><span>作者：测试作者</span></div></div></div><div class='comic-description'><p>测试简介</p></div><div class='chapter-list'><a href='\(mcChapterPath(host))'>01</a><a href='\(mcChapterPath(host,42,2))'>02</a><a href='\(mcChapterPath(host))'>重复</a><a href='https://evil.test\(mcChapterPath(host))'>外站</a><a href='\(mcChapterPath(host,99))'>其他作品</a></div>"
}
private let mcReader = "<img src='https://images.test/ad.webp'><div class='comic-content'><img class='comic-image' src='data:image/gif;base64,AA' data-src='https://images.test/1.webp'><img class='comic-image' src='https://images.test/2.webp'></div>"
private func mcAdapter(_ source: Source) throws -> any SourceAdapter {
    guard let adapter = BuiltinSources.candidateAdapter(for:source) else { throw CheckFailure(description:"Missing adapter for \(source.baseURL.host!)") }; return adapter
}
public let mcCMSChecks: [Check] = [
    Check("McCMSSourceTests.registrationPreservesExistingSourceIdentity") {
        let all = BuiltinSources.candidates()
        try expect(all.count == 14,"Append three sources without replacing existing entries")
        for (index, source) in all.enumerated() { try expect(source.id.rawValue.uuidString.hasSuffix(String(format:"%012d",100+index)),"Persisted source identity must retain its index") }
        try expect(all.filter{$0.baseURL.host == "www.duokanmh.com"}.count == 1,"Do not duplicate Duokan")
        let unavailable = all.first{$0.baseURL.host == "www.gugu5.com"}!
        try expect(unavailable.capabilities.isEmpty && unavailable.binding == nil && !unavailable.enabled && unavailable.name.contains("暂不可用"),"Unvalidated Gugu must be visibly unavailable")
        try expect(BuiltinSources.candidateAdapter(for: unavailable) == nil,"Do not fabricate a Gugu reader")
    }
] + ["www.77hh.net", "www.haokantxt.com"].flatMap { host in [
    Check("McCMSSourceTests.\(host).catalogDetailsCompleteChaptersAndImages") {
        let source = mcSource(host); let adapter = try mcAdapter(source)
        let workURL = URL(string:mcWorkPath(host),relativeTo:source.baseURL)!.absoluteURL
        let chapterURL = URL(string:mcChapterPath(host),relativeTo:source.baseURL)!.absoluteURL
        let search = source.baseURL.appendingPathComponent("search").appending(queryItems:[URLQueryItem(name:"key",value:"hero")])
        let home = "<section><h2>热门漫画</h2><a href='\(mcWorkPath(host))' title='测试作品'><img data-src='https://images.test/cover.webp'></a><a href='https://evil.test\(mcWorkPath(host))'>恶意</a></section>"
        let client = FixtureHTTPClient([source.baseURL.absoluteString:textResponse(home,source.baseURL),search.absoluteString:textResponse(home,search),workURL.absoluteString:textResponse(mcDetail(host),workURL),chapterURL.absoluteString:textResponse(mcReader,chapterURL)])
        let context = ParserContext(source:source,client:client)
        let works = try await adapter.browse(context:context)
        try expect(works.count == 1 && works[0].title == "测试作品" && works[0].coverURL?.host == "images.test","Parse catalog with lazy covers, excluding external works")
        try expect(try await adapter.search(query:"hero",context:context).count == 1,"Use live site's search endpoint")
        let work = try await adapter.details(url:workURL,context:context)
        try expect(work.title == "测试作品" && work.author == "测试作者" && work.summary == "测试简介","Parse detail metadata")
        let chapters = try await adapter.chapters(work:work,context:context)
        try expect(chapters.count == 2 && chapters.map(\.ordinal) == [0,1],"Keep full source order, deduplicate and exclude foreign work links")
        let pages = try await adapter.pages(chapter:chapters[0],context:context)
        try expect(pages.count == 2 && pages[0].request.url.absoluteString == "https://images.test/1.webp" && pages[1].ordinal == 1,"Prefer real lazy images and exclude advertisements")
        try expect(pages.allSatisfy{$0.request.referer == chapterURL},"Retain chapter referer for image downloads")
        let rec = try await adapter.recommendations(context:context)
        try expect(rec.sections.contains{$0.works.count == 1},"Expose source recommendations")
    },
    Check("McCMSSourceTests.\(host).rejectsMissingOrInvalidWorkMarker") {
        let source = mcSource(host); let adapter = try mcAdapter(source)
        let workURL = URL(string:mcWorkPath(host),relativeTo:source.baseURL)!.absoluteURL
        let work = SourceWork(id:SourceWorkID(sourceID:source.id,externalID:mcWorkPath(host)),title:"测试",url:workURL)
        for marker in ["", "<a class='j-user-collect' data-id='invalid'></a>"] {
            let html = marker + "<div class='chapter-list'><a href='\(mcChapterPath(host,99))'>其他作品</a></div>"
            let context = ParserContext(source:source,client:FixtureHTTPClient([workURL.absoluteString:textResponse(html,workURL)]))
            do { _ = try await adapter.chapters(work:work,context:context);throw CheckFailure(description:"Accepted foreign chapter list without independently verified work identity") } catch is MangaError {}
        }
    },
    Check("McCMSSourceTests.\(host).rejectsWrongWorkChapterAndRedirect") {
        let source = mcSource(host);let adapter = try mcAdapter(source)
        let workURL = URL(string:mcWorkPath(host),relativeTo:source.baseURL)!.absoluteURL
        let url = URL(string:mcChapterPath(host),relativeTo:source.baseURL)!.absoluteURL
        let workID = SourceWorkID(sourceID:source.id,externalID:mcWorkPath(host))
        let context = ParserContext(source:source,client:FixtureHTTPClient([workURL.absoluteString:textResponse(mcDetail(host),workURL),url.absoluteString:textResponse(mcReader,URL(string:mcChapterPath(host,42,2),relativeTo:source.baseURL)!.absoluteURL)]))
        for path in [mcChapterPath(host),mcChapterPath(host,99)] {
            let target = URL(string:path,relativeTo:source.baseURL)!.absoluteURL
            let chapter = Chapter(id:ChapterID(sourceWorkID:workID,externalID:path),title:"测试",url:target,ordinal:0)
            do { _ = try await adapter.pages(chapter:chapter,context:context);throw CheckFailure(description:"Accepted unlisted work chapter or different chapter redirect") } catch is MangaError {}
        }
        do { _ = try await adapter.details(url:URL(string:"https://evil.test\(mcWorkPath(host))")!,context:context);throw CheckFailure(description:"Accepted foreign detail") } catch MangaError.invalidURL {}
    }
] }
