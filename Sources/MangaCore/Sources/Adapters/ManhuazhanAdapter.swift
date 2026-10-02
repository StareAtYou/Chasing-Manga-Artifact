import Foundation
import SwiftSoup
public struct ManhuazhanAdapter: SourceAdapter {
    public let id = "manhuazhan-reader"
    public let version = 1
    public let capabilities: SourceCapabilities = [.browse, .search, .details, .chapters, .pages]
    public init() { }
    private var base: HTMLTemplateAdapter {
        var template = HTMLTemplate(); template.title = "h1"; template.cover = ".d-vod-pic img"; template.author = ".d-vod-type p:contains(作者)"; template.summary = ".d-des"; template.chapters = "a[href^='/chapter/']"; template.readerImages = "#ChapterContent img"; template.nextPage = "a[data-chapter-page-next]"
        return HTMLTemplateAdapter(id: id, template: template)
    }
    public func browse(context: ParserContext) async throws -> [SourceWork] { try await listing(ResourceRequest(url: context.source.baseURL), context: context) }
    public func search(query: String, context: ParserContext) async throws -> [SourceWork] {
        var components = URLComponents(); components.queryItems = [URLQueryItem(name: "key", value: query)]
        let body = Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "%20", with: "+").utf8)
        return try await listing(ResourceRequest(url: context.source.baseURL.appendingPathComponent("search"), headers: ["Content-Type": "application/x-www-form-urlencoded"], method: .post, body: body), context: context)
    }
    private func listing(_ request: ResourceRequest, context: ParserContext) async throws -> [SourceWork] {
        let response = try await context.client.send(request, sourceID: context.source.id, priority: .search)
        let doc = try SwiftSoup.parse(response.text); try HTMLAccessGuard.check(doc); var seen = Set<URL>(); var result: [SourceWork] = []
        for link in try doc.select("a[href*='/comic/']").array() {
            guard let url = resolvedWebURL(try link.attr("href"), relativeTo: response.finalURL), WebOrigin(url) == WebOrigin(context.source.baseURL), url.path.range(of: #"^/comic/\d+/?$"#, options: .regularExpression) != nil else { continue }
            let title = try link.attr("title").isEmpty ? link.text().trimmingCharacters(in: .whitespacesAndNewlines) : link.attr("title")
            guard !title.isEmpty, seen.insert(url).inserted else { continue }
            let cover = resolvedWebURL(try link.attr("data-background"), relativeTo: response.finalURL)
            result.append(SourceWork(id: SourceWorkID(sourceID: context.source.id, externalID: semanticID(url)), title: title, url: url, coverURL: cover, capabilities: capabilities))
        }
        return result
    }
    public func details(url: URL, context: ParserContext) async throws -> SourceWork { try await base.details(url: url, context: context) }
    public func chapters(work: SourceWork, context: ParserContext) async throws -> [Chapter] { try await base.chapters(work: work, context: context) }
    public func pages(chapter: Chapter, context: ParserContext) async throws -> [PageResource] {
        let html = try await context.text(chapter.url)
        guard html.contains("DATA=") || html.contains("DATA =") else { return try await base.pages(chapter: chapter, context: context) }
        guard let renderer = context.renderer else { throw MangaError.unsupported("该来源正文需要内置浏览器渲染") }
        let page = try await renderer.render(url: chapter.url, source: context.source, interactive: false)
        struct Item: Decodable { let url: String }
        guard let value = page.metadata["manhuazhan.pages"], let items = try? JSONDecoder().decode([Item].self, from: Data(value.utf8)), !items.isEmpty else { throw MangaError.parseMismatch("浏览器未取得正文列表") }
        return try items.enumerated().map { index, item in
            guard let url = resolvedWebURL(item.url, relativeTo: page.url) else { throw MangaError.parseMismatch("无效正文地址") }
            return PageResource(id: PageID(chapterID: chapter.id, externalID: "\(index + 1)"), ordinal: index, request: ResourceRequest(url: url, referer: page.url, accessContextID: page.accessContextID))
        }
    }
}
