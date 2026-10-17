import Foundation
import SwiftSoup
/// A reader-local document client. Browser navigation is serialized because the
/// platform renderer owns one WKWebView per source.
private actor GuaziReaderClient: HTTPClient {
    private static let browserSlots = RequestScheduler(globalLimit: 4, sourceLimit: 1)
    private let context: ParserContext
    private let workURL: URL
    private var browserPages: [URL: RenderedPage] = [:]
    init(context: ParserContext, workURL: URL) { self.context = context; self.workURL = workURL }
    func browserPage(for url: URL?) -> RenderedPage? { url.flatMap { browserPages[$0] } }
    func send(_ resource: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        guard sourceID == context.source.id, SourceScope.contains(resource.url, in: context.source.baseURL) else { throw MangaError.invalidURL }
        var request = resource
        request.referer = request.referer ?? workURL
        if !request.headers.keys.contains(where: { $0.lowercased() == "accept" }) { request.headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" }
        let response: ResourceResponse
        do {
            response = try await context.client.send(request, sourceID: sourceID, priority: priority)
            if response.statusCode == 403 { throw MangaError.accessRestricted(403) }
        } catch MangaError.accessRestricted(403) {
            guard let renderer = context.renderer else { throw MangaError.accessRestricted(403) }
            let lease = try await Self.browserSlots.acquire(sourceID: sourceID, priority: .reading)
            let page: RenderedPage
            do {
                try Task.checkCancellation()
                page = try await renderer.render(url: request.url, source: context.source, interactive: false)
                await Self.browserSlots.release(lease)
            } catch { await Self.browserSlots.release(lease); throw error }
            try Task.checkCancellation()
            try validate(page.url, requested: request.url)
            browserPages[request.url] = page
            return ResourceResponse(data: Data(page.html.utf8), finalURL: page.url, statusCode: 200)
        }
        try validate(response.finalURL, requested: request.url)
        return response
    }
    private func validate(_ url: URL, requested: URL) throws {
        guard SourceScope.contains(url, in: context.source.baseURL), semanticID(url) == semanticID(requested) else { throw MangaError.invalidURL }
    }
}
public struct GuaziAdapter: SourceAdapter {
    public let id = "guazi-html"
    public let version = 1
    public let capabilities: SourceCapabilities = [.browse, .search, .details, .chapters, .pages]
    private var base: HTMLTemplateAdapter {
        var template = HTMLTemplate()
        template.title = "#cinema-title, .mobile-comic-title"
        template.cover = ".mobile-comic-cover, .cinema-cover"
        template.author = ".cinema-strip a[href*=author.php]"
        template.summary = ".mobile-comic-desc"
        template.chapters = "[data-chapter-list] a[href*='chapter.php?id=']"
        template.readerImages = "img.reading-image"
        template.nextPage = "a[data-page-pagination]"
        return HTMLTemplateAdapter(id: id, template: template)
    }
    public init() { }
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
    public func browse(context: ParserContext) async throws -> [SourceWork] { try await listing(context.source.baseURL, context: context) }
    public func search(query: String, context: ParserContext) async throws -> [SourceWork] {
        let url = context.source.baseURL.appendingPathComponent("category.php").appending(queryItems: [URLQueryItem(name: "keyword", value: query)])
        return try await listing(url, context: context)
    }
    private func listing(_ url: URL, context: ParserContext) async throws -> [SourceWork] {
        let doc = try SwiftSoup.parse(await context.text(url, priority: .search))
        try HTMLAccessGuard.check(doc)
        var seen = Set<SourceWorkID>(); var result: [SourceWork] = []
        for element in try doc.select("a[href*='comic.php?id=']").array() {
            guard let link = resolvedWebURL(try element.attr("href"), relativeTo: url), WebOrigin(link) == WebOrigin(context.source.baseURL) else { continue }
            let titleElement = try element.select("h2,h3,.comic-name,.title").first()
            let image = try element.select("img").first()
            let candidates = try [titleElement?.text() ?? "", element.attr("title"), image?.attr("alt") ?? "", element.text()]
            guard let rawTitle = candidates.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { continue }
            let title = rawTitle.hasSuffix("漫画封面") ? String(rawTitle.dropLast(4)) : rawTitle
            let id = SourceWorkID(sourceID: context.source.id, externalID: semanticID(link))
            guard seen.insert(id).inserted else { continue }
            let cover = try image.flatMap { resolvedWebURL(try $0.attr("data-src").isEmpty ? $0.attr("src") : $0.attr("data-src"), relativeTo: url) }
            result.append(SourceWork(id: id, title: title, url: link, coverURL: cover, capabilities: capabilities))
        }
        return result
    }
    public func details(url: URL, context: ParserContext) async throws -> SourceWork { try await base.details(url: url, context: context) }
    public func chapters(work: SourceWork, context: ParserContext) async throws -> [Chapter] {
        let chapters = try await base.chapters(work: work, context: context)
        return chapters.reversed().enumerated().map { index, chapter in Chapter(id: chapter.id, title: chapter.title, url: chapter.url, ordinal: index, access: chapter.access) }
    }
    public func pages(chapter: Chapter, context: ParserContext) async throws -> [PageResource] {
        guard chapter.id.sourceWorkID.sourceID == context.source.id else { throw MangaError.invalidURL }
        let candidate = resolvedWebURL(chapter.id.sourceWorkID.externalID, relativeTo: context.source.baseURL)
        let workURL = candidate.flatMap { SourceScope.contains($0, in: context.source.baseURL) ? $0 : nil } ?? context.source.baseURL
        let client = GuaziReaderClient(context: context, workURL: workURL)
        let reader = ParserContext(source: context.source, client: client, renderer: context.renderer)
        let pages = try await base.pages(chapter: chapter, context: reader)
        var result: [PageResource] = []
        for (index, page) in pages.enumerated() {
            var request = page.request
            if let browser = await client.browserPage(for: request.referer) {
                request.accessContextID = browser.accessContextID
                if let userAgent = browser.metadata["reader.userAgent"] { request.headers["User-Agent"] = userAgent }
            }
            result.append(PageResource(id: PageID(chapterID: chapter.id, externalID: "\(index + 1)"), ordinal: index, request: request))
        }
        return result
    }
}
