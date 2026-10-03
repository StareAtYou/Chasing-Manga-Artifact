import Foundation
public struct ParserContext: Sendable {
    public let source: Source
    public let client: any HTTPClient
    public let renderer: (any PageRenderer)?
    public init(source: Source, client: any HTTPClient, renderer: (any PageRenderer)? = nil) { self.source = source; self.client = client; self.renderer = renderer }
    public func text(_ url: URL, priority: RequestPriority = .reading) async throws -> String {
        guard SourceScope.contains(url, in: source.baseURL) else { throw MangaError.invalidURL }
        let response = try await client.send(ResourceRequest(url: url), sourceID: source.id, priority: priority)
        guard SourceScope.contains(response.finalURL, in: source.baseURL) else { throw MangaError.unsupported("页面跳转到了其他来源，请确认并修改来源地址后重试") }
        return response.text
    }
}
public struct PageValidationSample: Sendable {
    public let totalCount: Int
    public let pages: [PageResource]
    public init(totalCount: Int, pages: [PageResource]) { self.totalCount = totalCount; self.pages = pages }
}
public protocol SourceAdapter: Sendable {
    var id: String { get }
    var version: Int { get }
    var capabilities: SourceCapabilities { get }
    func recommendations(context: ParserContext) async throws -> SourceRecommendations
    func catalogPage(channel: CatalogChannel, sort: CatalogSort, pageURL: URL?, context: ParserContext) async throws -> CatalogPage
    func browse(context: ParserContext) async throws -> [SourceWork]
    func search(query: String, context: ParserContext) async throws -> [SourceWork]
    func details(url: URL, context: ParserContext) async throws -> SourceWork
    func chapters(work: SourceWork, context: ParserContext) async throws -> [Chapter]
    func pages(chapter: Chapter, context: ParserContext) async throws -> [PageResource]
    func validationPages(chapter: Chapter, context: ParserContext) async throws -> PageValidationSample
}
public extension SourceAdapter {
    func recommendations(context: ParserContext) async throws -> SourceRecommendations {
        let works = try await browse(context: context)
        let series = ["xkcd.com", "www.xkcd.com", "www.qwantz.com"].contains(context.source.baseURL.host ?? "")
        let channel = CatalogChannel(id: "browse", title: series ? "原创系列" : "来源浏览", url: context.source.baseURL, kind: series ? .series : .browse)
        return SourceRecommendations(source: context.source, channels: [channel], sections: [CatalogSection(channel: channel, works: works)])
    }
    func catalogPage(channel: CatalogChannel, sort: CatalogSort = .sourceDefault, pageURL: URL? = nil, context: ParserContext) async throws -> CatalogPage {
        guard pageURL == nil, sort == .sourceDefault, channel.url == context.source.baseURL else { throw MangaError.unsupported("此来源暂不提供分类分页") }
        return CatalogPage(works: try await browse(context: context))
    }
    func validationPages(chapter: Chapter, context: ParserContext) async throws -> PageValidationSample {
        let pages = try await pages(chapter: chapter, context: context)
        return PageValidationSample(totalCount: pages.count, pages: pages)
    }
    func browse(context: ParserContext) async throws -> [SourceWork] { throw MangaError.unsupported("浏览") }
    func search(query: String, context: ParserContext) async throws -> [SourceWork] { throw MangaError.unsupported("搜索") }
}
public func resolvedWebURL(_ value: String, relativeTo base: URL) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL, WebOrigin(url) != nil, url.user == nil, url.password == nil else { return nil }
    return url
}
public func semanticID(_ url: URL) -> String {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.scheme = nil; components.host = nil; components.port = nil; components.fragment = nil
    return components.string ?? url.path
}
