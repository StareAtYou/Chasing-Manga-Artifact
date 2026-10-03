import Foundation

/// Public MangaDex API. Only hosted, available chapters are exposed as readable.
public struct MangaDexAdapter: SourceAdapter {
    public let id = "mangadex-api"
    public let version = 1
    public let capabilities: SourceCapabilities = [.browse, .search, .readable]
    public init() { }
    private struct RelationshipAttributes: Decodable { let name: String?; let fileName: String? }
    private struct Relationship: Decodable { let type: String; let attributes: RelationshipAttributes? }
    private struct Attributes: Decodable {
        let title: [String: String]?
        let altTitles: [[String: String]]?
        let description: [String: String]?
        let name: String?
        let fileName: String?
    }
    private struct Manga: Decodable { let id: String; let attributes: Attributes; let relationships: [Relationship] }
    private struct MangaEnvelope: Decodable { let result: String; let data: Manga }
    private struct MangaList: Decodable { let result: String; let data: [Manga] }
    private struct ChapterAttributes: Decodable {
        let chapter: String?; let title: String?; let translatedLanguage: String
        let pages: Int; let externalUrl: String?; let isUnavailable: Bool?
    }
    private struct ChapterItem: Decodable { let id: String; let attributes: ChapterAttributes; let relationships: [Relationship] }
    private struct Feed: Decodable { let result: String; let data: [ChapterItem]; let total: Int }
    private struct ImageList: Decodable { let hash: String; let data: [String]; let dataSaver: [String] }
    private struct AtHome: Decodable { let result: String; let baseUrl: String; let chapter: ImageList }
    private func endpoint(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        var value = URLComponents(string: "https://api.mangadex.org/" + path)!
        if !query.isEmpty { value.queryItems = query }
        return value.url!
    }
    private func item(_ name: String, _ value: String) -> URLQueryItem { URLQueryItem(name: name, value: value) }
    private func json<T: Decodable>(_ type: T.Type, url: URL, context: ParserContext) async throws -> T {
        guard ["mangadex.org", "www.mangadex.org"].contains(context.source.baseURL.host?.lowercased() ?? "") else { throw MangaError.invalidURL }
        let response = try await context.client.send(ResourceRequest(url: url, headers: ["Accept": "application/json"]), sourceID: context.source.id, priority: .reading)
        guard response.finalURL.host == "api.mangadex.org", let value = try? JSONDecoder().decode(type, from: response.data) else { throw MangaError.parseMismatch("MangaDex 接口格式已变化") }
        return value
    }
    private func preferred(_ values: [String: String]?) -> String {
        guard let values else { return "" }
        for language in ["zh", "zh-hk", "en", "ja-ro", "zh-ro", "ja"] { if let value = values[language], !value.isEmpty { return value } }
        return values.sorted { $0.key < $1.key }.first?.value ?? ""
    }
    private func work(_ manga: Manga, source: Source) throws -> SourceWork {
        guard UUID(uuidString: manga.id) != nil else { throw MangaError.parseMismatch("MangaDex 作品标识无效") }
        let alternatives = manga.attributes.altTitles ?? []
        let chinese = alternatives.compactMap { $0["zh"] ?? $0["zh-hk"] }.first
        let primary = preferred(manga.attributes.title)
        let title = manga.attributes.title?["zh"] ?? manga.attributes.title?["zh-hk"] ?? chinese ?? primary
        guard !title.isEmpty else { throw MangaError.parseMismatch("MangaDex 作品缺少标题") }
        let authors = Array(Set(manga.relationships.filter { ["author", "artist"].contains($0.type) }.compactMap { $0.attributes?.name })).sorted().joined(separator: " / ")
        let filename = manga.relationships.first { $0.type == "cover_art" }?.attributes?.fileName
        let cover = filename.flatMap { safeComponent($0) ? URL(string: "https://uploads.mangadex.org/covers/\(manga.id)/\($0).256.jpg") : nil }
        return SourceWork(id: SourceWorkID(sourceID: source.id, externalID: manga.id), title: title, url: source.baseURL.appendingPathComponent("title/" + manga.id), coverURL: cover, author: authors, aliases: Array(Set(alternatives.flatMap { $0.values } + [primary])).sorted(), summary: preferred(manga.attributes.description) + "\n来源：MangaDex", capabilities: capabilities)
    }
    private func listing(query: String?, context: ParserContext) async throws -> [SourceWork] {
        var parameters = [item("limit", "40"), item("contentRating[]", "safe"), item("includes[]", "cover_art")]
        if let query { parameters.append(item("title", query)) } else { parameters.append(item("order[latestUploadedChapter]", "desc")) }
        let value = try await json(MangaList.self, url: endpoint("manga", parameters), context: context)
        guard value.result == "ok" else { throw MangaError.parseMismatch("MangaDex 返回错误") }
        return try value.data.map { try work($0, source: context.source) }
    }
    public func browse(context: ParserContext) async throws -> [SourceWork] { try await listing(query: nil, context: context) }
    public func search(query: String, context: ParserContext) async throws -> [SourceWork] { try await listing(query: query, context: context) }
    public func details(url: URL, context: ParserContext) async throws -> SourceWork {
        guard SourceScope.contains(url, in: context.source.baseURL), url.pathComponents.count == 3, url.pathComponents[1] == "title", UUID(uuidString: url.lastPathComponent) != nil else { throw MangaError.invalidURL }
        let value = try await json(MangaEnvelope.self, url: endpoint("manga/" + url.lastPathComponent, [item("includes[]", "cover_art"), item("includes[]", "author"), item("includes[]", "artist")]), context: context)
        guard value.result == "ok", value.data.id == url.lastPathComponent else { throw MangaError.parseMismatch("MangaDex 作品不一致") }
        return try work(value.data, source: context.source)
    }
    public func chapters(work: SourceWork, context: ParserContext) async throws -> [Chapter] {
        guard work.id.sourceID == context.source.id, SourceScope.contains(work.url, in: context.source.baseURL), UUID(uuidString: work.id.externalID) != nil else { throw MangaError.invalidURL }
        var offset = 0; var result: [Chapter] = []; var seen = Set<String>()
        for _ in 0..<100 {
            try Task.checkCancellation()
            let value = try await json(Feed.self, url: endpoint("manga/\(work.id.externalID)/feed", [item("limit", "100"), item("offset", String(offset)), item("translatedLanguage[]", "zh"), item("translatedLanguage[]", "zh-hk"), item("translatedLanguage[]", "en"), item("order[chapter]", "asc"), item("includes[]", "scanlation_group")]), context: context)
            guard value.result == "ok", value.total >= 0 else { throw MangaError.parseMismatch("MangaDex 目录错误") }
            for chapter in value.data {
                let attributes = chapter.attributes
                guard UUID(uuidString: chapter.id) != nil, attributes.pages > 0, attributes.isUnavailable != true, attributes.externalUrl?.isEmpty != false, seen.insert(chapter.id).inserted else { continue }
                let groups = chapter.relationships.filter { $0.type == "scanlation_group" }.compactMap { $0.attributes?.name }.joined(separator: " / ")
                let title = [attributes.chapter.map { "第\($0)话" } ?? "番外", attributes.title ?? "", "[\(attributes.translatedLanguage)]", groups].filter { !$0.isEmpty }.joined(separator: " · ")
                result.append(Chapter(id: ChapterID(sourceWorkID: work.id, externalID: chapter.id), title: title, url: context.source.baseURL.appendingPathComponent("chapter/" + chapter.id), ordinal: result.count))
            }
            offset += value.data.count
            if offset >= value.total { return result }
            guard !value.data.isEmpty else { throw MangaError.parseMismatch("MangaDex 目录不完整，请稍后重试") }
        }
        throw MangaError.parseMismatch("MangaDex 目录超过读取上限")
    }
    private func safeComponent(_ value: String) -> Bool { !value.isEmpty && !value.contains("..") && value.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").inverted) == nil }
    public func pages(chapter: Chapter, context: ParserContext) async throws -> [PageResource] {
        guard chapter.id.sourceWorkID.sourceID == context.source.id, SourceScope.contains(chapter.url, in: context.source.baseURL), UUID(uuidString: chapter.id.externalID) != nil else { throw MangaError.invalidURL }
        let value = try await json(AtHome.self, url: endpoint("at-home/server/" + chapter.id.externalID, [item("forcePort443", "true")]), context: context)
        guard value.result == "ok", let base = URL(string: value.baseUrl), base.scheme == "https", base.user == nil, base.password == nil, let host = base.host, host.hasSuffix(".mangadex.network") || host.hasSuffix(".mangadex.org"), safeComponent(value.chapter.hash) else { throw MangaError.parseMismatch("MangaDex 正文地址无效") }
        let saver = !value.chapter.dataSaver.isEmpty && value.chapter.dataSaver.count == value.chapter.data.count
        let files = saver ? value.chapter.dataSaver : value.chapter.data
        guard !files.isEmpty, files.allSatisfy(safeComponent) else { throw MangaError.parseMismatch("MangaDex 正文列表为空或无效") }
        return files.enumerated().map { index, name in PageResource(id: PageID(chapterID: chapter.id, externalID: String(index + 1)), ordinal: index, request: ResourceRequest(url: base.appendingPathComponent(saver ? "data-saver" : "data").appendingPathComponent(value.chapter.hash).appendingPathComponent(name), referer: chapter.url)) }
    }
}
