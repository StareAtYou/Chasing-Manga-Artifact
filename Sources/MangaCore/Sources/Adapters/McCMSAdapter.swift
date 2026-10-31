import Foundation
import SwiftSoup

/// The public, static McCMS layout used by 77漫画 and 好看漫画.
public struct McCMSAdapter: SourceAdapter {
    public enum Site: Sendable { case seventySeven, haokan }
    public let site: Site
    public var id: String { site == .seventySeven ? "77-mccms" : "haokan-mccms" }
    public let version = 1
    public let capabilities: SourceCapabilities = [.browse, .search, .readable]
    private var host: String { site == .seventySeven ? "www.77hh.net" : "www.haokantxt.com" }
    private var separator: String { site == .seventySeven ? "-" : "_" }
    public init(site: Site) { self.site = site }

    private func validate(_ context: ParserContext) throws {
        let base = context.source.baseURL
        guard base.scheme == "https", base.host == host, base.port == nil || base.port == 443,
              base.user == nil, base.password == nil, base.path.isEmpty || base.path == "/", base.query == nil, base.fragment == nil else { throw MangaError.invalidURL }
    }
    private func local(_ url: URL, context: ParserContext) -> Bool {
        SourceScope.contains(url, in: context.source.baseURL) && url.query == nil && url.fragment == nil && url.user == nil && url.password == nil
    }
    private func isWork(_ url: URL, context: ParserContext) -> Bool {
        local(url, context: context) && url.path.range(of: "^/comic" + separator + "[A-Za-z0-9_-]+\\.html$", options: .regularExpression) != nil
    }
    private func chapterWorkID(_ url: URL, context: ParserContext) -> String? {
        guard local(url, context: context), url.path.range(of: "^/chapter" + separator + "[0-9]+" + separator + "[0-9]+\\.html$", options: .regularExpression) != nil else { return nil }
        return url.path.components(separatedBy: separator)[1]
    }
    private func document(_ url: URL, context: ParserContext, priority: RequestPriority = .reading) async throws -> Document {
        try validate(context)
        guard SourceScope.contains(url, in: context.source.baseURL) else { throw MangaError.invalidURL }
        let response = try await context.client.send(ResourceRequest(url: url, referer: context.source.baseURL,
            headers: ["User-Agent":"Mozilla/5.0", "Accept":"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"]), sourceID: context.source.id, priority: priority)
        guard SourceScope.contains(response.finalURL, in: context.source.baseURL), HTMLCatalogDiscovery.sameDocument(url, response.finalURL) else { throw MangaError.parseMismatch("页面跳转到了其他作品或章节") }
        let doc = try SwiftSoup.parse(response.text, url.absoluteString)
        try HTMLAccessGuard.check(doc)
        return doc
    }
    private func cover(_ element: Element, url: URL) throws -> URL? {
        for image in try element.select("img").array() {
            for attr in ["data-src", "data-original", "src"] {
                if let target = resolvedWebURL(try image.attr(attr), relativeTo: url) { return target }
            }
        }
        return nil
    }
    private func listing(_ doc: Document, url: URL, context: ParserContext) throws -> [SourceWork] {
        var works: [SourceWork] = []; var seen = Set<SourceWorkID>()
        for link in try doc.select("a[href]").array() {
            guard let target = resolvedWebURL(try link.attr("href"), relativeTo: url), isWork(target, context: context) else { continue }
            let titles = try [link.attr("title"),link.select("img").first()?.attr("alt") ?? "",link.text()]
            guard let title = titles.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { continue }
            let workID = SourceWorkID(sourceID: context.source.id, externalID: semanticID(target))
            guard seen.insert(workID).inserted else { continue }
            var image = try cover(link, url: url)
            // The cover and title links are siblings in source catalog cards.
            if image == nil, let parent = link.parent(), !["body","html"].contains(parent.tagName()) { image = try cover(parent, url: url) }
            works.append(SourceWork(id: workID, title: title, url: target, coverURL: image, capabilities: capabilities))
        }
        return works
    }
    public func browse(context: ParserContext) async throws -> [SourceWork] {
        try listing(await document(context.source.baseURL, context: context, priority: .search), url: context.source.baseURL, context: context)
    }
    public func search(query: String, context: ParserContext) async throws -> [SourceWork] {
        try validate(context)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var components = URLComponents(url: context.source.baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name:"key", value:query)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of:"+", with:"%2B")
        guard let url = components.url else { throw MangaError.invalidURL }
        return try listing(await document(url, context: context, priority: .search), url: url, context: context)
    }
    public func details(url: URL, context: ParserContext) async throws -> SourceWork {
        try validate(context); guard isWork(url, context: context) else { throw MangaError.invalidURL }
        let doc = try await document(url, context: context)
        var title = try doc.select(".comic-meta-info h1").first()?.text().trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { throw MangaError.parseMismatch("缺少作品标题") }
        if title.hasPrefix("《"), title.hasSuffix("》") { title = String(title.dropFirst().dropLast()) }
        var author = ""
        for span in try doc.select(".comic-stats span").array() {
            let value = try span.text()
            if value.hasPrefix("作者：") || value.hasPrefix("作者:") { author = String(value.dropFirst(3)).trimmingCharacters(in:.whitespacesAndNewlines); break }
        }
        let summary = try doc.select(".comic-description p").text()
        let scope = try doc.select(".comic-cover-large").first()
        return SourceWork(id:SourceWorkID(sourceID:context.source.id, externalID:semanticID(url)), title:title, url:url, coverURL:try scope.flatMap { try cover($0,url:url) }, author:author, summary:summary, capabilities:capabilities)
    }
    public func chapters(work: SourceWork, context: ParserContext) async throws -> [Chapter] {
        try validate(context)
        guard work.id.sourceID == context.source.id, isWork(work.url, context:context), work.id.externalID == semanticID(work.url) else { throw MangaError.invalidURL }
        let doc = try await document(work.url, context:context)
        guard let numericWork = try doc.select(".j-user-collect[data-id]").first()?.attr("data-id"),
              numericWork.range(of: "^[0-9]+$", options: .regularExpression) != nil else { throw MangaError.parseMismatch("缺少可信的作品编号") }
        var seen = Set<String>(); var result: [Chapter] = []
        for link in try doc.select(".chapter-list a[href]").array() {
            guard let url = resolvedWebURL(try link.attr("href"),relativeTo:work.url), let numeric = chapterWorkID(url, context:context) else { continue }
            guard numeric == numericWork else { continue }
            let external = semanticID(url); let title = try link.text().trimmingCharacters(in:.whitespacesAndNewlines)
            guard !title.isEmpty, seen.insert(external).inserted else { continue }
            result.append(Chapter(id:ChapterID(sourceWorkID:work.id,externalID:external), title:title, url:url, ordinal:result.count))
        }
        guard !result.isEmpty else { throw MangaError.parseMismatch("缺少完整章节目录") }
        return result
    }
    public func pages(chapter: Chapter, context: ParserContext) async throws -> [PageResource] {
        try validate(context)
        guard chapter.id.sourceWorkID.sourceID == context.source.id, chapter.id.externalID == semanticID(chapter.url),
              chapterWorkID(chapter.url, context:context) != nil, let workURL = resolvedWebURL(chapter.id.sourceWorkID.externalID,relativeTo:context.source.baseURL), isWork(workURL,context:context) else { throw MangaError.invalidURL }
        let work = SourceWork(id:chapter.id.sourceWorkID,title:"",url:workURL)
        guard try await chapters(work:work,context:context).contains(where:{$0.id == chapter.id && $0.url == chapter.url}) else { throw MangaError.parseMismatch("章节不属于当前作品") }
        let doc = try await document(chapter.url,context:context)
        let images = try doc.select(".comic-content img.comic-image").array()
        guard !images.isEmpty, images.count <= 10_000 else { throw MangaError.parseMismatch("正文图片列表无效") }
        return try images.enumerated().map { index, element in
            let lazy = try element.attr("data-src"); let value = try lazy.isEmpty ? element.attr("src") : lazy
            guard let url = resolvedWebURL(value,relativeTo:chapter.url) else { throw MangaError.parseMismatch("正文包含无效图片地址") }
            return PageResource(id:PageID(chapterID:chapter.id,externalID:String(index+1)),ordinal:index,request:ResourceRequest(url:url,referer:chapter.url,headers:["User-Agent":"Mozilla/5.0"]))
        }
    }
    public func recommendations(context: ParserContext) async throws -> SourceRecommendations {
        try validate(context)
        let catalog = ParserContext(source:context.source,client:McCMSDocumentHeaders(client:context.client,baseURL:context.source.baseURL),renderer:context.renderer)
        return try await HTMLCatalogDiscovery.recommendations(adapter:self,context:catalog)
    }
    public func catalogPage(channel: CatalogChannel, sort: CatalogSort, pageURL: URL?, context: ParserContext) async throws -> CatalogPage {
        try validate(context)
        let url = try pageURL ?? HTMLCatalogDiscovery.sortedURL(channel,sort:sort,source:context.source)
        guard SourceScope.contains(url,in:context.source.baseURL) else { throw MangaError.invalidURL }
        let doc = try await document(url,context:context,priority:.search)
        return try HTMLCatalogDiscovery.page(html:doc.outerHtml(),works:listing(doc,url:url,context:context),url:url,source:context.source)
    }
}
private struct McCMSDocumentHeaders: HTTPClient {
    let client: any HTTPClient
    let baseURL: URL
    func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        var request = request; request.headers["User-Agent"] = "Mozilla/5.0"; request.referer = request.referer ?? baseURL
        let response = try await client.send(request,sourceID:sourceID,priority:priority)
        guard SourceScope.contains(response.finalURL,in:baseURL), HTMLCatalogDiscovery.sameDocument(request.url,response.finalURL) else { throw MangaError.parseMismatch("页面跳转到了其他分类") }
        return response
    }
}
