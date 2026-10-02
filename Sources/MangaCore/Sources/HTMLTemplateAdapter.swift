import Foundation
import SwiftSoup
public struct HTMLTemplate: Codable, Sendable {
    public var title = "[data-manga-title], .manga-title"
    public var workLinks = "a[data-work-id]"
    public var chapters = "a[data-chapter-id]"
    public var readerImages = "[data-manga-reader] img"
    public var nextPage = "a[data-reader-next]"
    public var searchPath: String? = nil
    public init() { }
}
public struct HTMLTemplateAdapter: SourceAdapter {
    public let id: String
    public let version = 1
    public let template: HTMLTemplate
    public var capabilities: SourceCapabilities { template.searchPath == nil ? [.browse, .details, .chapters, .pages] : [.browse, .search, .details, .chapters, .pages] }
    public init(id: String = "html-declared-v1", template: HTMLTemplate = HTMLTemplate()) { self.id = id; self.template = template }
    private func document(_ html: String, url: URL) throws -> Document {
        let document = try SwiftSoup.parse(html, url.absoluteString)
        let title = try document.title().lowercased()
        if ["just a moment", "access denied", "验证", "captcha"].contains(where: title.contains) { throw MangaError.verificationRequired }
        return document
    }
    public func browse(context: ParserContext) async throws -> [SourceWork] { try await listing(url: context.source.baseURL, context: context) }
    public func search(query: String, context: ParserContext) async throws -> [SourceWork] {
        guard let path = template.searchPath else { throw MangaError.unsupported("搜索") }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?"))) ?? ""
        guard let url = resolvedWebURL(path.replacingOccurrences(of: "{query}", with: encoded), relativeTo: context.source.baseURL) else { throw MangaError.invalidURL }
        return try await listing(url: url, context: context)
    }
    private func listing(url: URL, context: ParserContext) async throws -> [SourceWork] {
        let doc = try document(await context.text(url, priority: .search), url: url)
        var seen = Set<SourceWorkID>()
        return try doc.select(template.workLinks).array().compactMap { element in
            guard let link = resolvedWebURL(try element.attr("href"), relativeTo: url) else { return nil }
            let title = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let declared = try element.attr("data-work-id")
            let id = SourceWorkID(sourceID: context.source.id, externalID: declared.isEmpty ? semanticID(link) : declared)
            guard seen.insert(id).inserted else { return nil }
            let image = try element.select("img").first()
            return SourceWork(id: id, title: title, url: link, coverURL: try image.flatMap { resolvedWebURL(try $0.attr("src"), relativeTo: url) }, capabilities: capabilities)
        }
    }
    public func details(url: URL, context: ParserContext) async throws -> SourceWork {
        let doc = try document(await context.text(url, priority: .probe), url: url)
        guard let element = try doc.select(template.title).first() else { throw MangaError.parseMismatch("缺少作品标题") }
        let title = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MangaError.parseMismatch("作品标题为空") }
        let declared = try element.attr("data-work-id")
        let id = SourceWorkID(sourceID: context.source.id, externalID: declared.isEmpty ? semanticID(url) : declared)
        return SourceWork(id: id, title: title, url: url, capabilities: capabilities)
    }
    public func chapters(work: SourceWork, context: ParserContext) async throws -> [Chapter] {
        let doc = try document(await context.text(work.url, priority: .probe), url: work.url)
        var result: [Chapter] = []; var seen = Set<String>()
        for element in try doc.select(template.chapters).array() {
            guard let url = resolvedWebURL(try element.attr("href"), relativeTo: work.url) else { continue }
            let explicit = try element.attr("data-chapter-id"); let external = explicit.isEmpty ? semanticID(url) : explicit
            guard seen.insert(external).inserted else { continue }
            let title = try element.text(); guard !title.isEmpty else { continue }
            result.append(Chapter(id: ChapterID(sourceWorkID: work.id, externalID: external), title: title, url: url, ordinal: result.count))
        }
        return result
    }
    public func pages(chapter: Chapter, context: ParserContext) async throws -> [PageResource] {
        var next: URL? = chapter.url; var visited = Set<URL>(); var seen = Set<String>(); var result: [PageResource] = []
        while let url = next, visited.insert(url).inserted {
            try Task.checkCancellation()
            guard visited.count <= 100 else { throw MangaError.parseMismatch("章节分页过多") }
            let doc = try document(await context.text(url), url: url)
            let images = try doc.select(template.readerImages).array()
            guard !images.isEmpty else { throw MangaError.parseMismatch("缺少正文区域") }
            for image in images {
                let candidates = try ["data-src", "data-original", "src"].map { try image.attr($0) }
                guard let resource = candidates.compactMap({ resolvedWebURL($0, relativeTo: url) }).first else { continue }
                let name = resource.lastPathComponent.lowercased()
                guard !["loading", "placeholder", "advert", "banner"].contains(where: name.contains) else { continue }
                var identity = URLComponents(url: resource, resolvingAgainstBaseURL: false)!
                identity.queryItems = identity.queryItems?.filter { !["sign", "signature", "token", "expires", "expiry", "key"].contains($0.name.lowercased()) }; identity.fragment = nil
                let explicit = try image.attr("data-page-id")
                let external = explicit.isEmpty ? (identity.string ?? resource.path) : explicit
                guard seen.insert(external).inserted else { continue }
                result.append(PageResource(id: PageID(chapterID: chapter.id, externalID: external), ordinal: result.count, request: ResourceRequest(url: resource, referer: url)))
            }
            next = try doc.select(template.nextPage).first().flatMap { resolvedWebURL(try $0.attr("href"), relativeTo: url) }
            if let candidate = next, WebOrigin(candidate) != WebOrigin(chapter.url) { throw MangaError.parseMismatch("正文分页跳转到其他网站") }
        }
        guard !result.isEmpty else { throw MangaError.parseMismatch("没有有效正文图片") }
        return result
    }
}
