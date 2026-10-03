import Foundation
import SwiftSoup
/// baozimh.org's public website, distinct from the unavailable .com site.
public struct BaoziAdapter: SourceAdapter {
    public let id = "baozimh-org-reader"
    public let version = 1
    public let capabilities: SourceCapabilities = [.browse, .search, .readable]
    public init() { }
    private func document(_ url: URL, context: ParserContext) async throws -> Document {
        guard context.source.baseURL.host == "baozimh.org" else { throw MangaError.invalidURL }
        let doc = try SwiftSoup.parse(await context.text(url), url.absoluteString)
        try HTMLAccessGuard.check(doc);return doc
    }
    private func listing(_ url: URL, context: ParserContext) async throws -> [SourceWork] {
        let doc = try await document(url, context: context)
        var seen = Set<URL>();var result: [SourceWork] = []
        for link in try doc.select("a[href*='/manga/']").array() {
            guard let workURL = resolvedWebURL(try link.attr("href"), relativeTo: url), SourceScope.contains(workURL, in: context.source.baseURL), workURL.path.range(of: #"^/manga/[^/]+/?$"#, options: .regularExpression) != nil, seen.insert(workURL).inserted else { continue }
            let image = try link.select("img").first()
            let title = try link.select("h3, h2, p.line-clamp-2").first()?.text() ?? link.attr("title")
            let fallback = try image?.attr("alt") ?? ""
            let name = title.isEmpty ? fallback : title
            guard !name.isEmpty else { continue }
            result.append(SourceWork(id: SourceWorkID(sourceID: context.source.id, externalID: semanticID(workURL)), title: name, url: workURL, coverURL: try image.flatMap { resolvedWebURL(try $0.attr("src"), relativeTo: url) }, capabilities: capabilities))
        }
        return result
    }
    public func browse(context: ParserContext) async throws -> [SourceWork] { try await listing(context.source.baseURL, context: context) }
    public func search(query: String, context: ParserContext) async throws -> [SourceWork] {
        var components = URLComponents(url: context.source.baseURL.appendingPathComponent("s"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return try await listing(components.url!, context: context)
    }
    public func details(url: URL, context: ParserContext) async throws -> SourceWork {
        guard url.path.range(of: #"^/manga/[^/]+/?$"#, options: .regularExpression) != nil else { throw MangaError.invalidURL }
        let doc = try await document(url, context: context)
        let title = try doc.select("h1").first()?.ownText().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, try doc.select("#mangachapters[data-mid]").first() != nil else { throw MangaError.parseMismatch("包子漫画详情结构不匹配") }
        let cover = try doc.select("meta[property='og:image']").first()?.attr("content") ?? ""
        let author = try doc.select("a[href^='/manga-author/']").array().map { try $0.text() }.joined(separator: " / ")
        let summary = try doc.select("meta[name='description']").first()?.attr("content") ?? ""
        return SourceWork(id: SourceWorkID(sourceID: context.source.id, externalID: semanticID(url)), title: title, url: url, coverURL: resolvedWebURL(cover, relativeTo: url), author: author, summary: summary, capabilities: capabilities)
    }
    private struct Envelope: Decodable { let status: Bool; let data: Manga }
    private struct Manga: Decodable { let id: String; let slug: String; let chapters: [Item] }
    private struct Item: Decodable { let id: String; let attributes: Attributes }
    private struct Attributes: Decodable { let title: String; let slug: String; let order: Int }
    public func chapters(work: SourceWork, context: ParserContext) async throws -> [Chapter] {
        guard work.id.sourceID == context.source.id else { throw MangaError.invalidURL }
        let doc = try await document(work.url, context: context)
        guard let mid = try doc.select("#mangachapters[data-mid]").first()?.attr("data-mid"), Int(mid) != nil else { throw MangaError.parseMismatch("包子漫画缺少目录标识") }
        var components = URLComponents(string: "https://v2.apikk.top/api/manga/get")!
        components.queryItems = [URLQueryItem(name: "mid", value: mid), URLQueryItem(name: "mode", value: "all")]
        // The public site's fetch uses its Origin and Referer. These are public
        // request context, with no hardcoded access tokens or user credentials.
        let response = try await context.client.send(ResourceRequest(url: components.url!, referer: work.url, headers: ["Origin": "https://baozimh.org", "Accept": "application/json", "User-Agent": "Mozilla/5.0"]), sourceID: context.source.id, priority: .reading)
        guard response.finalURL.host == "v2.apikk.top", let value = try? JSONDecoder().decode(Envelope.self, from: response.data), value.status, value.data.id == mid, value.data.slug == work.url.lastPathComponent else { throw MangaError.parseMismatch("包子漫画目录格式不匹配") }
        var result: [Chapter] = [];var seen = Set<String>()
        for item in value.data.chapters.sorted(by: { $0.attributes.order < $1.attributes.order }) {
            guard !item.attributes.title.isEmpty, !item.attributes.slug.isEmpty, !item.attributes.slug.contains("/"), !item.attributes.slug.contains(".."), seen.insert(item.id).inserted else { continue }
            let url = work.url.appendingPathComponent(item.attributes.slug)
            result.append(Chapter(id: ChapterID(sourceWorkID: work.id, externalID: semanticID(url)), title: item.attributes.title, url: url, ordinal: result.count))
        }
        return result
    }
    public func pages(chapter: Chapter, context: ParserContext) async throws -> [PageResource] {
        guard context.source.baseURL.host == "baozimh.org", chapter.id.sourceWorkID.sourceID == context.source.id, SourceScope.contains(chapter.url, in: context.source.baseURL) else { throw MangaError.invalidURL }
        guard let renderer = context.renderer else { throw MangaError.unsupported("包子漫画正文需要内置浏览器") }
        let page = try await renderer.render(url: chapter.url, source: context.source, interactive: false)
        guard SourceScope.contains(page.url, in: context.source.baseURL) else { throw MangaError.invalidURL }
        let doc = try SwiftSoup.parse(page.html);try HTMLAccessGuard.check(doc)
        let images = try doc.select("#chapcontent img[data-src]").array()
        guard !images.isEmpty else { throw MangaError.parseMismatch("包子漫画未返回正文，原站可能需要验证或暂时无法访问") }
        return try images.enumerated().map { index, image in
            guard let url = resolvedWebURL(try image.attr("data-src"), relativeTo: page.url) else { throw MangaError.parseMismatch("包子漫画正文地址无效") }
            return PageResource(id: PageID(chapterID: chapter.id, externalID: String(index + 1)), ordinal: index, request: ResourceRequest(url: url, referer: page.url, accessContextID: page.accessContextID))
        }
    }
}
