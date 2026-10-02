import Foundation
public struct ParserContext: Sendable {
    public let source: Source
    public let client: any HTTPClient
    public let renderer: (any PageRenderer)?
    public init(source: Source, client: any HTTPClient, renderer: (any PageRenderer)? = nil) { self.source = source; self.client = client; self.renderer = renderer }
    public func text(_ url: URL, priority: RequestPriority = .reading) async throws -> String {
        try await client.send(ResourceRequest(url: url), sourceID: source.id, priority: priority).text
    }
}
public protocol SourceAdapter: Sendable {
    var id: String { get }
    var version: Int { get }
    var capabilities: SourceCapabilities { get }
    func browse(context: ParserContext) async throws -> [SourceWork]
    func search(query: String, context: ParserContext) async throws -> [SourceWork]
    func details(url: URL, context: ParserContext) async throws -> SourceWork
    func chapters(work: SourceWork, context: ParserContext) async throws -> [Chapter]
    func pages(chapter: Chapter, context: ParserContext) async throws -> [PageResource]
}
public extension SourceAdapter {
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
