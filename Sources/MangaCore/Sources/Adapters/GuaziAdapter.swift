import Foundation
import SwiftSoup
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
            guard let title = candidates.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { continue }
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
        let pages = try await base.pages(chapter: chapter, context: context)
        return pages.enumerated().map { index, page in
            PageResource(id: PageID(chapterID: chapter.id, externalID: "\(index + 1)"), ordinal: index, request: page.request)
        }
    }
}
