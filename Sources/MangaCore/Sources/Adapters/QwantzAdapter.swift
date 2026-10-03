import Foundation
import SwiftSoup

/// Ryan North's public Dinosaur Comics archive; the complete series is one work.
public struct QwantzAdapter: SourceAdapter {
    public let id = "qwantz-reader"
    public let version = 1
    public let capabilities: SourceCapabilities = [.browse, .search, .readable]
    public init() { }

    private func validateSource(_ source: Source) throws {
        guard source.baseURL.scheme == "https", source.baseURL.host == "www.qwantz.com",
              source.baseURL.port == nil || source.baseURL.port == 443,
              source.baseURL.path == "/", source.baseURL.query == nil,
              source.baseURL.user == nil, source.baseURL.password == nil else { throw MangaError.invalidURL }
    }
    private func document(_ url: URL, context: ParserContext) async throws -> Document {
        try validateSource(context.source)
        let document = try SwiftSoup.parse(await context.text(url), url.absoluteString)
        try HTMLAccessGuard.check(document)
        return document
    }
    private func number(in url: URL, base: URL) -> String? {
        guard SourceScope.contains(url, in: base), url.path == "/index.php",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let values = (components.queryItems ?? []).filter { $0.name == "comic" }
        guard values.count == 1, let value = values.first?.value,
              value.range(of: #"^[1-9][0-9]{0,8}$"#, options: .regularExpression) != nil else { return nil }
        return value
    }
    private func comicURL(_ number: String, base: URL) -> URL {
        var components = URLComponents(url: base.appendingPathComponent("index.php"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "comic", value: number)]
        return components.url!
    }
    // The official archive still uses HTTP links. Upgrade only the same host's
    // default-port links, then apply the normal exact-origin source boundary.
    private func archiveURL(_ value: String, base: URL) -> URL? {
        guard let resolved = resolvedWebURL(value, relativeTo: base),
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else { return nil }
        if components.scheme == "http", components.host == base.host,
           components.port == nil || components.port == 80 {
            components.scheme = base.scheme
            components.port = base.port
        }
        guard let url = components.url, let number = number(in: url, base: base) else { return nil }
        return comicURL(number, base: base)
    }
    private func currentComic(_ document: Document, base: URL) throws -> (number: String, image: URL, description: String) {
        let permalink = try document.select("meta[property='og:url']").first()?.attr("content") ?? ""
        guard let url = resolvedWebURL(permalink, relativeTo: base), let number = number(in: url, base: base) else {
            throw MangaError.parseMismatch("恐龙漫画缺少当前期标识")
        }
        let imageValue = try document.select("meta[property='og:image']").first()?.attr("content") ?? ""
        guard let image = resolvedWebURL(imageValue, relativeTo: base),
              SourceScope.contains(image, in: base), image.path.hasPrefix("/comics/"),
              image.path != "/comics/" else { throw MangaError.parseMismatch("恐龙漫画正文地址无效") }
        // Match the site's explicit body marker and metadata. Other /comics/
        // assets (including future-comic previews) are not reader pages.
        let body = try document.select("img.comic").array().contains { element in
            try resolvedWebURL(element.attr("src"), relativeTo: base) == image
        }
        guard body else { throw MangaError.parseMismatch("恐龙漫画正文与页面元数据不匹配") }
        let description = try document.select("meta[property='og:description']").first()?.attr("content") ?? ""
        return (number, image, description)
    }
    public func details(url: URL, context: ParserContext) async throws -> SourceWork {
        try validateSource(context.source)
        guard SourceScope.contains(url, in: context.source.baseURL), url.path == "/", url.query == nil else { throw MangaError.invalidURL }
        let document = try await document(url, context: context)
        let current = try currentComic(document, base: context.source.baseURL)
        return SourceWork(id: SourceWorkID(sourceID: context.source.id, externalID: "qwantz"), title: "Dinosaur Comics（恐龙漫画）", url: context.source.baseURL, coverURL: current.image, author: "Ryan North", summary: "Ryan North 创作的英文原创网络漫画。来源：Dinosaur Comics 官方网站。\n" + current.description, latestChapter: "第\(current.number)期", capabilities: capabilities)
    }
    public func browse(context: ParserContext) async throws -> [SourceWork] {
        [try await details(url: context.source.baseURL, context: context)]
    }
    public func search(query: String, context: ParserContext) async throws -> [SourceWork] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let aliases = ["dinosaur comics", "恐龙漫画", "qwantz", "ryan north"]
        guard !query.isEmpty, aliases.contains(where: { $0.contains(query) || query.contains($0) }) else { return [] }
        return try await browse(context: context)
    }
    public func chapters(work: SourceWork, context: ParserContext) async throws -> [Chapter] {
        try validateSource(context.source)
        guard work.id.sourceID == context.source.id, work.id.externalID == "qwantz",
              SourceScope.contains(work.url, in: context.source.baseURL), work.url.path == "/", work.url.query == nil else { throw MangaError.invalidURL }
        let document = try await document(context.source.baseURL.appendingPathComponent("archive.php"), context: context)
        var seen = Set<String>()
        var entries: [(String, URL, String)] = []
        for link in try document.select("ul.archive li a[href]").array() {
            guard let url = archiveURL(try link.attr("href"), base: context.source.baseURL),
                  let number = number(in: url, base: context.source.baseURL), seen.insert(number).inserted else { continue }
            let date = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append((number, url, "第\(number)期" + (date.isEmpty ? "" : " · " + date)))
        }
        guard !entries.isEmpty else { throw MangaError.parseMismatch("恐龙漫画目录结构不匹配") }
        return entries.reversed().enumerated().map { ordinal, entry in
            Chapter(id: ChapterID(sourceWorkID: work.id, externalID: entry.0), title: entry.2, url: entry.1, ordinal: ordinal)
        }
    }
    public func pages(chapter: Chapter, context: ParserContext) async throws -> [PageResource] {
        try validateSource(context.source)
        guard chapter.id.sourceWorkID.sourceID == context.source.id, chapter.id.sourceWorkID.externalID == "qwantz",
              number(in: chapter.url, base: context.source.baseURL) == chapter.id.externalID else { throw MangaError.invalidURL }
        let document = try await document(chapter.url, context: context)
        let current = try currentComic(document, base: context.source.baseURL)
        // Missing/deleted IDs can return a successful homepage instead of 404.
        guard current.number == chapter.id.externalID else { throw MangaError.parseMismatch("恐龙漫画返回了其他期，当前期可能已移除") }
        return [PageResource(id: PageID(chapterID: chapter.id, externalID: "1"), ordinal: 0, request: ResourceRequest(url: current.image, referer: chapter.url))]
    }
}
