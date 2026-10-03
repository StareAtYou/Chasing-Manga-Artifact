import Foundation
import SwiftSoup
/// Uses the same public chapter image endpoint requested by MangaBZ's reader.
/// Packed responses are decoded as known string literals, never executed.
public struct MangaBZAdapter: SourceAdapter {
    public let id = "mangabz-reader"
    public let version = 1
    public let capabilities: SourceCapabilities = [.browse, .search, .readable]
    public init() { }
    private func document(_ url: URL, context: ParserContext) async throws -> Document {
        guard context.source.baseURL.host == "www.mangabz.com" else { throw MangaError.invalidURL }
        let html = try await context.text(url)
        if html.contains("您所在地区无法观看该漫画") { throw MangaError.regionRestricted }
        let doc = try SwiftSoup.parse(html);try HTMLAccessGuard.check(doc);return doc
    }
    private func canonicalWorkURL(_ url:URL,context:ParserContext) -> URL? {
        guard SourceScope.contains(url,in:context.source.baseURL),let mid=DM5ReaderData.captures(#"^/(\d+)bz/?$"#,in:url.path)?.first else {return nil}
        return context.source.baseURL.appendingPathComponent(mid+"bz/")
    }
    private func listing(_ url: URL, context: ParserContext) async throws -> [SourceWork] {
        let doc = try await document(url,context:context);var seen=Set<URL>();var result:[SourceWork]=[]
        for link in try doc.select("a[href]").array() {
            guard let linkURL=resolvedWebURL(try link.attr("href"),relativeTo:url),let target=canonicalWorkURL(linkURL,context:context) else {continue}
            var title=try link.attr("title")
            if title.isEmpty {title=try link.select("img").first()?.attr("alt") ?? link.text()}
            guard !title.isEmpty,seen.insert(target).inserted else {continue}
            var container:Element?=link
            while let current=container, !current.hasClass("mh-item"), !current.hasClass("banner-item"), !current.hasClass("index-manga-item") {container=current.parent()}
            let image=try (container ?? link).select("img").first()
            let cover=try image.flatMap {resolvedWebURL(try $0.attr("data-original").isEmpty ? $0.attr("src") : $0.attr("data-original"),relativeTo:url)}
            result.append(SourceWork(id:SourceWorkID(sourceID:context.source.id,externalID:semanticID(target)),title:title,url:target,coverURL:cover,capabilities:capabilities))
        }
        return result
    }
    public func recommendations(context: ParserContext) async throws -> SourceRecommendations {
        try await HTMLCatalogDiscovery.recommendations(adapter: self, context: context, rootURL: context.source.baseURL)
    }
    public func catalogPage(channel: CatalogChannel, sort: CatalogSort, pageURL: URL?, context: ParserContext) async throws -> CatalogPage {
        let url: URL
        if let pageURL { url = pageURL } else { url = try HTMLCatalogDiscovery.sortedURL(channel, sort: sort, source: context.source) }
        guard SourceScope.contains(url, in: context.source.baseURL) else { throw MangaError.invalidURL }
        let context = HTMLCatalogDiscovery.catalogContext(context)
        let works = try await listing(url, context: context)
        return try HTMLCatalogDiscovery.page(html: await context.text(url), works: works, url: url, source: context.source)
    }
    public func browse(context:ParserContext) async throws -> [SourceWork] {try await listing(context.source.baseURL,context:context)}
    public func search(query:String,context:ParserContext) async throws -> [SourceWork] {
        var components=URLComponents(url:context.source.baseURL.appendingPathComponent("search/"),resolvingAgainstBaseURL:false)!
        components.queryItems=[URLQueryItem(name:"title",value:query)]
        return try await listing(components.url!,context:context)
    }
    public func details(url:URL,context:ParserContext) async throws -> SourceWork {
        guard let canonical=canonicalWorkURL(url,context:context) else {throw MangaError.invalidURL}
        let doc=try await document(url,context:context)
        let title=try doc.select(".detail-info-title").first()?.text() ?? ""
        guard !title.isEmpty,try doc.select("#chapterlistload").first() != nil else {throw MangaError.parseMismatch("MangaBZ 详情结构不匹配")}
        let cover=try doc.select(".detail-info-cover").first().flatMap {resolvedWebURL(try $0.attr("src"),relativeTo:url)}
        let author=try doc.select(".detail-info-tip a[href*='f=2']").array().map{try $0.text()}.joined(separator:" / ")
        let summary=try doc.select(".detail-info-content").first()?.text() ?? ""
        return SourceWork(id:SourceWorkID(sourceID:context.source.id,externalID:semanticID(canonical)),title:title,url:canonical,coverURL:cover,author:author,summary:summary,capabilities:capabilities)
    }
    public func chapters(work:SourceWork,context:ParserContext) async throws -> [Chapter] {
        guard work.id.sourceID == context.source.id,work.id.externalID == semanticID(work.url) else {throw MangaError.invalidURL}
        let doc=try await document(work.url,context:context);var seen=Set<URL>();var result:[Chapter]=[]
        for link in try doc.select("#chapterlistload a[href]").array().reversed() {
            guard let url=resolvedWebURL(try link.attr("href"),relativeTo:work.url),SourceScope.contains(url,in:context.source.baseURL),url.path.range(of:#"^/m\d+/?$"#,options:.regularExpression) != nil,seen.insert(url).inserted else {continue}
            let access:ChapterAccess=try link.hasClass("pay") || link.select(".vip,.pay").size()>0 ? .paid : .available
            result.append(Chapter(id:ChapterID(sourceWorkID:work.id,externalID:semanticID(url)),title:try link.text(),url:url,ordinal:result.count,access:access))
        }
        return result
    }
    private struct ReaderData:Sendable {let count:Int;let parameters:[String:String]}
    private func readerData(chapter:Chapter,context:ParserContext) async throws -> ReaderData {
        guard chapter.access == .available else {throw MangaError.chapterUnavailable}
        guard chapter.id.sourceWorkID.sourceID == context.source.id,chapter.id.externalID == semanticID(chapter.url),chapter.url.path.range(of:#"^/m\d+/?$"#,options:.regularExpression) != nil else {throw MangaError.invalidURL}
        let doc=try await document(chapter.url,context:context);let html=try doc.outerHtml()
        if try DM5ReaderData.stringVariable("isVip",in:html)?.lowercased() == "true" {throw MangaError.chapterUnavailable}
        guard let count=DM5ReaderData.captures(#"MANGABZ_IMAGE_COUNT\s*=\s*(\d+)"#,in:html)?.first.flatMap(Int.init),(1...1000).contains(count),
              let cid=DM5ReaderData.captures(#"MANGABZ_CID\s*=\s*(\d+)"#,in:html)?.first,chapter.url.path.trimmingCharacters(in:CharacterSet(charactersIn:"/")) == "m\(cid)",
              let mid=DM5ReaderData.captures(#"MANGABZ_MID\s*=\s*(\d+)"#,in:html)?.first,chapter.id.sourceWorkID.externalID == "/\(mid)bz/",
              let date=try DM5ReaderData.stringVariable("MANGABZ_VIEWSIGN_DT",in:html),let sign=try DM5ReaderData.stringVariable("MANGABZ_VIEWSIGN",in:html) else {throw MangaError.parseMismatch("MangaBZ 缺少公开阅读上下文")}
        return ReaderData(count:count,parameters:["cid":cid,"key":"","_cid":cid,"_mid":mid,"_dt":date,"_sign":sign])
    }
    public func pages(chapter:Chapter,context:ParserContext) async throws -> [PageResource] {
        let data=try await readerData(chapter:chapter,context:context)
        // The site's endpoint supplies the requested page plus its next-page
        // preload. Reuse that pair; fall back if only one URL is supplied.
        return try await withThrowingTaskGroup(of:[PageResource].self) {group in
            for page in stride(from:1,through:data.count,by:2) {
                group.addTask {
                    let urls=try await imageURLs(chapter:chapter,data:data,page:page,context:context)
                    var result=[resource(url:urls[0],chapter:chapter,page:page)]
                    if page<data.count {
                        let next:URL
                        if urls.count>1 {next=urls[1]}
                        else {next=try await imageURLs(chapter:chapter,data:data,page:page+1,context:context)[0]}
                        result.append(resource(url:next,chapter:chapter,page:page+1))
                    }
                    return result
                }
            }
            var result:[PageResource]=[];for try await pair in group {result.append(contentsOf:pair)}
            return result.sorted{$0.ordinal<$1.ordinal}
        }
    }
    private func resource(url:URL,chapter:Chapter,page:Int) -> PageResource {
        PageResource(id:PageID(chapterID:chapter.id,externalID:String(page)),ordinal:page-1,request:ResourceRequest(url:url,referer:chapter.url))
    }
    private func imageURLs(chapter:Chapter,data:ReaderData,page:Int,context:ParserContext) async throws -> [URL] {
        var params=data.parameters;params["page"]=String(page)
        var components=URLComponents(url:chapter.url.appendingPathComponent("chapterimage.ashx"),resolvingAgainstBaseURL:false)!
        components.queryItems=params.sorted{$0.key<$1.key}.map{URLQueryItem(name:$0.key,value:$0.value)}
        let response=try await context.client.send(ResourceRequest(url:components.url!,referer:chapter.url,headers:["X-Requested-With":"XMLHttpRequest"]),sourceID:context.source.id,priority:.reading)
        guard SourceScope.contains(response.finalURL,in:context.source.baseURL) else {throw MangaError.invalidURL}
        let urls=try DM5ReaderData.urls(from:response.text,base:chapter.url)
        guard !urls.isEmpty else {throw MangaError.parseMismatch("MangaBZ 正文地址无效")}
        return urls
    }
    public func validationPages(chapter:Chapter,context:ParserContext) async throws -> PageValidationSample {
        let data=try await readerData(chapter:chapter,context:context)
        return PageValidationSample(totalCount:data.count,pages:try await resources(chapter:chapter,data:data,indices:data.count == 1 ? [1] : [1,data.count],context:context))
    }
    private func resources(chapter:Chapter,data:ReaderData,indices:[Int],context:ParserContext) async throws -> [PageResource] {
        try await withThrowingTaskGroup(of:PageResource.self) {group in
            for page in indices {
                group.addTask {
                    let urls=try await imageURLs(chapter:chapter,data:data,page:page,context:context)
                    return resource(url:urls[0],chapter:chapter,page:page)
                }
            }
            var result:[PageResource]=[];for try await page in group {result.append(page)}
            return result.sorted{$0.ordinal<$1.ordinal}
        }
    }
}
