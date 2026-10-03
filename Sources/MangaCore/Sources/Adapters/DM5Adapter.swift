import Foundation
import SwiftSoup
public struct DM5Adapter: SourceAdapter {
    public let id = "dm5-reader"
    public let version = 1
    public let capabilities: SourceCapabilities = [.browse, .search, .details, .chapters, .pages]
    public init() { }
    private func checked(_ html: String) throws -> Document {
        if html.contains("您所在地区无法观看该漫画") { throw MangaError.regionRestricted }
        let doc = try SwiftSoup.parse(html); try HTMLAccessGuard.check(doc); return doc
    }
    public func recommendations(context: ParserContext) async throws -> SourceRecommendations {
        try await HTMLCatalogDiscovery.recommendations(adapter: self, context: context, rootURL: context.source.baseURL)
    }
    public func catalogPage(channel: CatalogChannel, sort: CatalogSort, pageURL: URL?, context: ParserContext) async throws -> CatalogPage {
        let url: URL
        if let pageURL { url = pageURL } else { url = try HTMLCatalogDiscovery.sortedURL(channel, sort: sort, source: context.source) }
        guard SourceScope.contains(url, in: context.source.baseURL) else { throw MangaError.invalidURL }
        let works = try await listing(url, context: context)
        return try HTMLCatalogDiscovery.page(html: await context.text(url), works: works, url: url, source: context.source)
    }
    public func browse(context: ParserContext) async throws -> [SourceWork] { try await listing(context.source.baseURL, context: context) }
    public func search(query: String, context: ParserContext) async throws -> [SourceWork] { try await listing(context.source.baseURL.appendingPathComponent("search").appending(queryItems: [URLQueryItem(name: "title", value: query), URLQueryItem(name: "language", value: "1")]), context: context) }
    private func listing(_ url: URL, context: ParserContext) async throws -> [SourceWork] {
        let doc = try checked(await context.text(url, priority: .search)); var seen = Set<URL>(); var result: [SourceWork] = []
        for link in try doc.select("a[href^='/manhua-']").array() {
            guard let target = resolvedWebURL(try link.attr("href"), relativeTo: url), seen.insert(target).inserted else { continue }
            let declared = try link.attr("title")
            var container: Element? = link
            while let current = container, !(current.hasClass("mh-item") || current.hasClass("banner_detail_form")) { container = current.parent() }
            let directImage = try link.select("img").first()
            guard !declared.isEmpty || container != nil || directImage != nil else { continue }
            let title = try declared.isEmpty ? link.select("img").first()?.attr("alt") ?? link.text() : declared
            guard !title.isEmpty else { continue }
            let image = try (container ?? link).select("img").first()
            let style = try (container ?? link).select(".mh-cover").first()?.attr("style") ?? ""
            let cssCover = DM5ReaderData.captures(#"url\(\s*['"]?([^'")]+)"#, in: style)?.first ?? ""
            let candidates = try [cssCover, image?.attr("data-original") ?? "", image?.attr("data-src") ?? "", image?.attr("src") ?? "", link.attr("data-background")]
            let cover = candidates.lazy.compactMap { resolvedWebURL($0, relativeTo: url) }.first
            result.append(SourceWork(id: SourceWorkID(sourceID: context.source.id, externalID: semanticID(target)), title: title, url: target, coverURL: cover, capabilities: capabilities))
        }
        return result
    }
    public func details(url: URL, context: ParserContext) async throws -> SourceWork {
        let doc = try checked(await context.text(url, priority: .probe))
        guard let element = try doc.select(".banner_detail_form .info > .title").first() else { throw MangaError.parseMismatch("缺少 DM5 作品标题") }
        let title = element.ownText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MangaError.parseMismatch("作品标题为空") }
        let cover = try doc.select(".banner_detail_form .cover img").first().flatMap { resolvedWebURL(try $0.attr("src"), relativeTo: url) }
        return SourceWork(id: SourceWorkID(sourceID: context.source.id, externalID: semanticID(url)), title: title, url: url, coverURL: cover, capabilities: capabilities)
    }
    public func chapters(work: SourceWork, context: ParserContext) async throws -> [Chapter] {
        let doc = try checked(await context.text(work.url, priority: .probe))
        var seen = Set<URL>(); var result: [Chapter] = []
        let links = try doc.select("#chapterlistload a, #chapter-list-1 a, .chapter-list a, #detail-list-select-1 a, .view-comment-sub a[href^='/m']").array()
        for link in links {
            guard let url = resolvedWebURL(try link.attr("href"), relativeTo: work.url), url.path.range(of: #"^/m\d+/?$"#, options: .regularExpression) != nil, seen.insert(url).inserted else { continue }
            let access: ChapterAccess = try link.hasClass("pay") || link.select(".vip,.pay").size() > 0 ? .paid : .available
            result.append(Chapter(id: ChapterID(sourceWorkID: work.id, externalID: semanticID(url)), title: try link.text(), url: url, ordinal: result.count, access: access))
        }
        return result.reversed().enumerated().map { index, chapter in Chapter(id: chapter.id, title: chapter.title, url: chapter.url, ordinal: index, access: chapter.access) }
    }
    private struct ReaderData: Sendable { let count: Int; let parameters: [String: String] }
    private func readerData(chapter: Chapter, context: ParserContext) async throws -> ReaderData {
        guard chapter.access == .available else { if chapter.access == .login { throw MangaError.requiresLogin }; throw MangaError.chapterUnavailable }
        let html = try await context.text(chapter.url)
        _ = try checked(html)
        if DM5ReaderData.captures(#"DM5_IS_PAY\s*=\s*(1|true)"#, in: html) != nil { throw MangaError.chapterUnavailable }
        guard let countText = DM5ReaderData.captures(#"DM5_IMAGE_COUNT\s*=\s*(\d+)"#, in: html)?.first, let count = Int(countText), (1...1000).contains(count),
              let cid = DM5ReaderData.captures(#"DM5_CID\s*=\s*(\d+)"#, in: html)?.first,
              let mid = DM5ReaderData.captures(#"DM5_MID\s*=\s*(\d+)"#, in: html)?.first,
              let date = try DM5ReaderData.stringVariable("DM5_VIEWSIGN_DT", in: html), let sign = try DM5ReaderData.stringVariable("DM5_VIEWSIGN", in: html) else { throw MangaError.parseMismatch("缺少公开阅读上下文") }
        let doc = try SwiftSoup.parse(html); let key = try doc.select("#dm5_key").first()?.attr("value") ?? ""
        return ReaderData(count: count, parameters: ["cid": cid, "key": key, "language": "1", "gtk": "6", "_cid": cid, "_mid": mid, "_dt": date, "_sign": sign])
    }
    public func pages(chapter: Chapter, context: ParserContext) async throws -> [PageResource] {
        let data = try await readerData(chapter: chapter, context: context)
        return try await resources(chapter: chapter, data: data, indices: Array(1...data.count), context: context)
    }
    public func validationPages(chapter: Chapter, context: ParserContext) async throws -> PageValidationSample {
        let data = try await readerData(chapter: chapter, context: context)
        let pages = try await resources(chapter: chapter, data: data, indices: data.count == 1 ? [1] : [1, data.count], context: context)
        return PageValidationSample(totalCount: data.count, pages: pages)
    }
    private func resources(chapter: Chapter, data: ReaderData, indices: [Int], context: ParserContext) async throws -> [PageResource] {
        return try await withThrowingTaskGroup(of: PageResource.self) { group in
            for page in indices {
                group.addTask {
                    var params = data.parameters; params["page"] = String(page)
                    let endpoint = chapter.url.appendingPathComponent("chapterfun.ashx").appending(queryItems: params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
                    let request = ResourceRequest(url: endpoint, referer: chapter.url, headers: ["X-Requested-With": "XMLHttpRequest"])
                    let response = try await context.client.send(request, sourceID: context.source.id, priority: .reading)
                    guard let url = try DM5ReaderData.urls(from: response.text, base: chapter.url).first else { throw MangaError.parseMismatch("缺少当前页") }
                    return PageResource(id: PageID(chapterID: chapter.id, externalID: String(page)), ordinal: page - 1, request: ResourceRequest(url: url, referer: chapter.url))
                }
            }
            var result: [PageResource] = []
            for try await page in group { result.append(page) }
            return result.sorted { $0.ordinal < $1.ordinal }
        }
    }
}
