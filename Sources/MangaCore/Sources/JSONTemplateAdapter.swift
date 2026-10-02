import Foundation
public struct JSONTemplateAdapter: SourceAdapter {
    public let id = "json-declared-v1"
    public let version = 1
    public let capabilities: SourceCapabilities = [.browse, .details, .chapters, .pages]
    public init() { }
    private struct Envelope: Decodable {
        let schemaVersion: Int
        var works: [WorkItem]?
        var work: WorkItem?
        var chapters: [ChapterItem]?
        var pages: [PageItem]?
    }
    private struct WorkItem: Decodable { let id: String; let title: String; let url: String; var coverURL: String?; var author: String? }
    private struct ChapterItem: Decodable { let id: String; let title: String; let url: String; let ordinal: Int }
    private struct PageItem: Decodable { let id: String; let ordinal: Int; let url: String }
    private func envelope(_ url: URL, context: ParserContext) async throws -> Envelope {
        let response = try await context.client.send(ResourceRequest(url: url), sourceID: context.source.id, priority: .probe)
        guard let decoded = try? JSONDecoder().decode(Envelope.self, from: response.data), decoded.schemaVersion == 1 else { throw MangaError.parseMismatch("未知 JSON 结构") }
        return decoded
    }
    private func work(_ item: WorkItem, base: URL, source: Source) throws -> SourceWork {
        guard !item.id.isEmpty, !item.title.isEmpty, let url = resolvedWebURL(item.url, relativeTo: base) else { throw MangaError.parseMismatch("无效作品字段") }
        return SourceWork(id: SourceWorkID(sourceID: source.id, externalID: item.id), title: item.title, url: url, coverURL: item.coverURL.flatMap { resolvedWebURL($0, relativeTo: base) }, author: item.author ?? "", capabilities: capabilities)
    }
    public func browse(context: ParserContext) async throws -> [SourceWork] {
        guard let items = try await envelope(context.source.baseURL, context: context).works else { throw MangaError.parseMismatch("缺少 works") }
        return try items.map { try work($0, base: context.source.baseURL, source: context.source) }
    }
    public func details(url: URL, context: ParserContext) async throws -> SourceWork {
        guard let item = try await envelope(url, context: context).work else { throw MangaError.parseMismatch("缺少 work") }
        return try work(item, base: url, source: context.source)
    }
    public func chapters(work: SourceWork, context: ParserContext) async throws -> [Chapter] {
        guard let items = try await envelope(work.url, context: context).chapters else { throw MangaError.parseMismatch("缺少 chapters") }
        var seen = Set<String>()
        return try items.sorted { $0.ordinal < $1.ordinal }.map { item in
            guard !item.id.isEmpty, seen.insert(item.id).inserted, let url = resolvedWebURL(item.url, relativeTo: work.url) else { throw MangaError.parseMismatch("无效或重复章节") }
            return Chapter(id: ChapterID(sourceWorkID: work.id, externalID: item.id), title: item.title, url: url, ordinal: item.ordinal)
        }
    }
    public func pages(chapter: Chapter, context: ParserContext) async throws -> [PageResource] {
        guard let items = try await envelope(chapter.url, context: context).pages, !items.isEmpty else { throw MangaError.parseMismatch("缺少 pages") }
        var seen = Set<String>(); var ordinals = Set<Int>()
        return try items.sorted { $0.ordinal < $1.ordinal }.map { item in
            guard !item.id.isEmpty, item.ordinal >= 0, seen.insert(item.id).inserted, ordinals.insert(item.ordinal).inserted, let url = resolvedWebURL(item.url, relativeTo: chapter.url) else { throw MangaError.parseMismatch("无效或重复页") }
            return PageResource(id: PageID(chapterID: chapter.id, externalID: item.id), ordinal: item.ordinal, request: ResourceRequest(url: url, referer: chapter.url))
        }
    }
}
