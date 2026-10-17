import Foundation
import SwiftSoup

/// Adapts the two public CMS reader formats without running website scripts.
public struct CMSMangaAdapter: SourceAdapter {
    public enum Site: Sendable { case duokan, fengche }
    public let site: Site
    public var id: String { site == .duokan ? "duokan-cms" : "fengche-cms" }
    public let version = 1
    public let capabilities: SourceCapabilities = [.browse, .search, .readable]
    private var host: String { site == .duokan ? "www.duokanmh.com" : "www.fengchemh.com" }
    private var workPrefix: String { site == .duokan ? "/manhua/" : "/comic/" }
    private static let browserSlots = RequestScheduler(globalLimit: 4, sourceLimit: 1)
    public init(site: Site) { self.site = site }

    private func validate(_ context: ParserContext) throws {
        let url = context.source.baseURL
        guard url.scheme == "https", url.host == host, url.port == nil || url.port == 443,
              url.path == "/" || url.path.isEmpty, url.query == nil, url.fragment == nil else { throw MangaError.invalidURL }
    }
    private func isWork(_ url: URL, context: ParserContext) -> Bool {
        SourceScope.contains(url, in: context.source.baseURL) && url.query == nil && url.fragment == nil &&
        url.path.range(of: "^" + workPrefix + "[A-Za-z0-9_-]+/?$", options: .regularExpression) != nil
    }
    private func isChapter(_ url: URL, work: SourceWorkID, context: ParserContext) -> Bool {
        guard SourceScope.contains(url, in: context.source.baseURL), url.query == nil, url.fragment == nil else { return false }
        let pattern = site == .duokan ? "^" + NSRegularExpression.escapedPattern(for: work.externalID.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) + "/[0-9]+\\.html$" : "^chapter/[A-Za-z0-9_-]+\\.html$"
        return String(url.path.dropFirst()).range(of: pattern, options: .regularExpression) != nil
    }
    private func document(_ url: URL, context: ParserContext, priority: RequestPriority = .reading) async throws -> Document {
        try validate(context)
        guard SourceScope.contains(url, in: context.source.baseURL) else { throw MangaError.invalidURL }
        let response = try await context.client.send(ResourceRequest(url: url, referer: context.source.baseURL,
            headers: ["User-Agent":"Mozilla/5.0", "Accept":"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"]), sourceID: context.source.id, priority: priority)
        guard HTMLCatalogDiscovery.sameDocument(url, response.finalURL), SourceScope.contains(response.finalURL, in: context.source.baseURL) else { throw MangaError.parseMismatch("页面地址与请求不一致") }
        let doc = try SwiftSoup.parse(response.text, url.absoluteString)
        do { try HTMLAccessGuard.check(doc); return doc }
        catch MangaError.verificationRequired where url.path == "/search" {
            // Reuse the source browser if the user has completed its verification.
            // A remaining challenge is still reported; it is never solved here.
            guard let renderer = context.renderer else { throw MangaError.verificationRequired }
            let lease = try await Self.browserSlots.acquire(sourceID: context.source.id, priority: priority)
            let page: RenderedPage
            do { page = try await renderer.render(url: url, source: context.source, interactive: false); await Self.browserSlots.release(lease) }
            catch { await Self.browserSlots.release(lease); throw error }
            try Task.checkCancellation()
            guard SourceScope.contains(page.url, in: context.source.baseURL), HTMLCatalogDiscovery.sameDocument(url, page.url) else { throw MangaError.invalidURL }
            let verified = try SwiftSoup.parse(page.html, page.url.absoluteString)
            try HTMLAccessGuard.check(verified)
            return verified
        }
    }
    private func imageURL(_ value: String, relativeTo url: URL) -> URL? {
        guard var resolved = resolvedWebURL(value, relativeTo: url) else { return nil }
        // This site emits its own covers as HTTP even on HTTPS pages.
        if resolved.host == host, resolved.scheme == "http", var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) {
            components.scheme = "https"; guard let secure = components.url else { return nil }; resolved = secure
        }
        return resolved
    }
    private func cover(_ scope: Element, url: URL) throws -> URL? {
        let selector = site == .duokan ? ".comic-cover, .comic-cover img, img" : ".img-wrapper, img"
        for image in try scope.select(selector).array() {
            for key in ["data-original", "data-src", "data-background", "src"] {
                if let value = imageURL(try image.attr(key), relativeTo: url) { return value }
            }
        }
        return nil
    }
    private func listing(_ doc: Document, url: URL, context: ParserContext) throws -> [SourceWork] {
        var result: [SourceWork] = []; var seen = Set<SourceWorkID>()
        for link in try doc.select("a[href]").array() {
            guard let target = resolvedWebURL(try link.attr("href"), relativeTo: url), isWork(target, context: context) else { continue }
            let text = try link.attr("title").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = text.isEmpty ? try link.text().trimmingCharacters(in: .whitespacesAndNewlines) : text
            guard !title.isEmpty else { continue }
            let identifier = SourceWorkID(sourceID: context.source.id, externalID: semanticID(target))
            guard seen.insert(identifier).inserted else { continue }
            var scope = link; var image: URL?
            for _ in 0..<5 {
                image = try cover(scope, url: url)
                if image != nil { break }
                guard let parent = scope.parent(), !["html","body"].contains(parent.tagName()) else { break }; scope = parent
            }
            result.append(SourceWork(id: identifier, title: title, url: target, coverURL: image, capabilities: capabilities))
        }
        return result
    }
    public func browse(context: ParserContext) async throws -> [SourceWork] {
        try listing(await document(context.source.baseURL, context: context, priority: .search), url: context.source.baseURL, context: context)
    }
    public func search(query: String, context: ParserContext) async throws -> [SourceWork] {
        try validate(context)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var components = URLComponents(url: context.source.baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: site == .duokan ? "q" : "key", value: query)]
        // Form endpoints interpret a literal '+' as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw MangaError.invalidURL }
        return try listing(await document(url, context: context, priority: .search), url: url, context: context)
    }
    public func details(url: URL, context: ParserContext) async throws -> SourceWork {
        try validate(context); guard isWork(url, context: context) else { throw MangaError.invalidURL }
        let doc = try await document(url, context: context, priority: .probe)
        let selector = site == .duokan ? ".comic-detail h1.title > span:not(.score)" : ".vod-info .info h1 a"
        let title = try doc.select(selector).first()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { throw MangaError.parseMismatch("缺少作品标题") }
        let scope = try doc.select(site == .duokan ? ".comic-detail" : ".vod-info").first() ?? doc
        var author = ""
        for element in try scope.select("p span, .data").array() {
            let text = try element.text()
            if text.hasPrefix("作者：") || text.hasPrefix("作者:") { author = String(text.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines); break }
        }
        var summary = try scope.select(".desc").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for prefix in ["简介：","简介:"] where summary.hasPrefix(prefix) { summary = String(summary.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let coverScope = try doc.select(site == .duokan ? ".comic-cover-box" : ".vod-info").first() ?? scope
        return SourceWork(id: SourceWorkID(sourceID: context.source.id, externalID: semanticID(url)), title: title, url: url,
                          coverURL: try cover(coverScope, url: url), author: author, summary: summary, capabilities: capabilities)
    }
    public func chapters(work: SourceWork, context: ParserContext) async throws -> [Chapter] {
        try validate(context)
        guard work.id.sourceID == context.source.id, isWork(work.url, context: context) else { throw MangaError.invalidURL }
        let doc = try await document(work.url, context: context, priority: .probe)
        let selector = site == .duokan ? ".chapter-list a[href]" : ".ewave-playlist-content a[href]"
        var result: [Chapter] = []; var seen = Set<String>()
        for link in try doc.select(selector).array() {
            guard let url = resolvedWebURL(try link.attr("href"), relativeTo: work.url), isChapter(url, work: work.id, context: context) else { continue }
            let title = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
            let external = semanticID(url)
            guard !title.isEmpty, seen.insert(external).inserted else { continue }
            result.append(Chapter(id: ChapterID(sourceWorkID: work.id, externalID: external), title: title, url: url, ordinal: result.count))
        }
        guard !result.isEmpty else { throw MangaError.parseMismatch("缺少完整章节目录") }
        return result
    }
    public func pages(chapter: Chapter, context: ParserContext) async throws -> [PageResource] {
        try validate(context)
        guard chapter.id.sourceWorkID.sourceID == context.source.id, isChapter(chapter.url, work: chapter.id.sourceWorkID, context: context) else { throw MangaError.invalidURL }
        let doc = try await document(chapter.url, context: context)
        let payload = try CMSReaderData.envelope(html: doc.outerHtml(), key: site == .duokan ? "5V&RoR%Jf@pJPydF" : "9S8$vJnU2ANeSRoF")
        guard payload["host"] as? String == host else { throw MangaError.parseMismatch("阅读数据属于其他来源") }
        if payload["comic_status"] as? String == "down" || (payload["comic_down"] as? Int ?? 0) != 0 { throw MangaError.workUnavailable }
        let images: [String]
        if site == .duokan {
            guard payload["comic_url"] as? String == chapter.id.sourceWorkID.externalID,
                  payload["chapter_url"] as? String == semanticID(chapter.url), let values = payload["chapter_images"] as? [String] else { throw MangaError.parseMismatch("章节阅读数据与请求不一致") }
            images = values
        } else {
            guard let values = payload["images"] as? [String] else { throw MangaError.parseMismatch("缺少正文图片列表") }; images = values
        }
        guard !images.isEmpty, images.count <= 10_000 else { throw MangaError.parseMismatch("正文页数无效") }
        let imageHost = (payload["images_hosts"] as? [String])?.first
        return try images.enumerated().map { index, raw in
            var value = raw; var encoding: ImageEncoding?
            if site == .duokan, let imageHost {
                if payload["images_base64"] as? Bool == true { value = imageHost.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + Data(raw.utf8).base64EncodedString() }
                else if !raw.hasPrefix("https://"), !raw.hasPrefix("http://"), !raw.hasPrefix("//") { value = imageHost.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + raw.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            }
            if site == .fengche, payload["source_id"] as? Int == 12, raw.hasPrefix("/") && !raw.hasPrefix("//") {
                value = "https://img1.baipiaoguai.org" + raw; encoding = .fengcheAES
            }
            guard let image = imageURL(value, relativeTo: chapter.url) else { throw MangaError.parseMismatch("正文包含无效图片地址") }
            let url = image
            let request = ResourceRequest(url: url, referer: encoding == nil ? chapter.url : nil, headers: ["User-Agent":"Mozilla/5.0"], imageEncoding: encoding)
            return PageResource(id: PageID(chapterID: chapter.id, externalID: String(index + 1)), ordinal: index, request: request)
        }
    }
    public func recommendations(context: ParserContext) async throws -> SourceRecommendations {
        let catalog = ParserContext(source: context.source, client: CMSDocumentHeaders(client: context.client, source: context.source), renderer: context.renderer)
        var snapshot = try await HTMLCatalogDiscovery.recommendations(adapter: self, context: catalog)
        var documents = [(try await document(context.source.baseURL, context: context), context.source.baseURL)]
        let categories = context.source.baseURL.appendingPathComponent(site == .duokan ? "fenlei/area/guoman" : "category/list/1")
        documents.append((try await document(categories, context: context), categories))
        let aliases = ["国产漫画":"国漫","日本漫画":"日漫","韩国漫画":"韩漫","欧美漫画":"欧美"]
        for (doc, url) in documents {
            for link in try doc.select("a[href]").array() {
                let title = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
                guard let target = resolvedWebURL(try link.attr("href"), relativeTo: url), SourceScope.contains(target, in: context.source.baseURL),
                      target.path.hasPrefix(site == .duokan ? "/fenlei/" : "/category/"), !CatalogTaxonomy.isPaginationURL(target),
                      let genre = CatalogTaxonomy.genreName(aliases[title] ?? title),
                      genre.range(of: #"^(?:第\s*\d+\s*[话章回]|\d+\s*[.、])"#, options: .regularExpression) == nil else { continue }
                let channel = CatalogChannel(id: target.absoluteString, title: genre, url: target, kind: .genre, genre: genre)
                snapshot.channels.removeAll { $0.id == channel.id }; snapshot.channels.append(channel)
            }
        }
        snapshot.channels.removeAll { $0.kind == .genre && $0.title.range(of: #"^(?:第\s*\d+\s*[话章回]|\d+\s*[.、])"#, options: .regularExpression) != nil }
        return CatalogTaxonomy.cleaned(snapshot)
    }
    public func catalogPage(channel: CatalogChannel, sort: CatalogSort, pageURL: URL?, context: ParserContext) async throws -> CatalogPage {
        guard sort == .sourceDefault else { throw MangaError.unsupported("此来源暂不提供该排序") }
        let url = pageURL ?? channel.url
        let doc = try await document(url, context: context, priority: .search)
        return try HTMLCatalogDiscovery.page(html: doc.outerHtml(), works: listing(doc, url: url, context: context), url: url, source: context.source)
    }
}

// The catalog helper also reads the document, so it needs the same public HTML
// headers as the adapter rather than a second request with the app's default UA.
private struct CMSDocumentHeaders: HTTPClient {
    let client: any HTTPClient
    let source: Source
    func send(_ resource: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        guard sourceID == source.id, SourceScope.contains(resource.url, in: source.baseURL) else { throw MangaError.invalidURL }
        var request = resource
        request.headers["User-Agent"] = "Mozilla/5.0"
        request.headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        request.referer = request.referer ?? source.baseURL
        return try await client.send(request, sourceID: sourceID, priority: priority)
    }
}
