import Foundation
/// Creator-provided public JSON interface; the entire numbered series is one work.
public struct XKCDAdapter: SourceAdapter {
    public let id = "xkcd-json"
    public let version = 1
    public let capabilities: SourceCapabilities = [.browse, .search, .readable]
    public init() { }
    private struct Comic: Decodable { let num: Int; let safe_title: String; let img: String; let alt: String }
    private func comic(_ number: Int? = nil, context: ParserContext) async throws -> Comic {
        guard ["xkcd.com", "www.xkcd.com"].contains(context.source.baseURL.host ?? "") else { throw MangaError.invalidURL }
        let path = number.map { "\($0)/info.0.json" } ?? "info.0.json"
        let response = try await context.client.send(ResourceRequest(url: context.source.baseURL.appendingPathComponent(path)), sourceID: context.source.id, priority: .reading)
        guard SourceScope.contains(response.finalURL, in: context.source.baseURL), let value = try? JSONDecoder().decode(Comic.self, from: response.data), value.num > 0, value.num <= 100_000, number == nil || value.num == number else { throw MangaError.parseMismatch("xkcd JSON 无效") }
        return value
    }
    public func details(url: URL, context: ParserContext) async throws -> SourceWork {
        guard SourceScope.contains(url, in: context.source.baseURL), url.path == "/" else { throw MangaError.invalidURL }
        let latest = try await comic(context: context)
        return SourceWork(id: SourceWorkID(sourceID: context.source.id, externalID: "xkcd"), title: "xkcd", url: context.source.baseURL, coverURL: resolvedWebURL(latest.img, relativeTo: url), author: "Randall Munroe", summary: "英文原创网络漫画。来源：xkcd 官方 JSON。\n" + latest.alt, latestChapter: "第\(latest.num)期 · \(latest.safe_title)", capabilities: capabilities)
    }
    public func browse(context: ParserContext) async throws -> [SourceWork] { [try await details(url: context.source.baseURL, context: context)] }
    public func search(query: String, context: ParserContext) async throws -> [SourceWork] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty, "xkcd randall munroe 兰德尔 门罗".contains(query) || query.contains("xkcd") else { return [] }
        return try await browse(context: context)
    }
    public func chapters(work: SourceWork, context: ParserContext) async throws -> [Chapter] {
        guard work.id.sourceID == context.source.id, work.id.externalID == "xkcd" else { throw MangaError.invalidURL }
        let latest = try await comic(context: context)
        var result: [Chapter] = []
        for number in 1...latest.num where number != 404 {
            let title = "第\(number)期" + (number == latest.num ? " · " + latest.safe_title : "")
            let id = ChapterID(sourceWorkID: work.id, externalID: String(number))
            let url = context.source.baseURL.appendingPathComponent("\(number)/")
            result.append(Chapter(id: id, title: title, url: url, ordinal: result.count))
        }
        return result
    }
    public func pages(chapter: Chapter, context: ParserContext) async throws -> [PageResource] {
        guard chapter.id.sourceWorkID.sourceID == context.source.id, SourceScope.contains(chapter.url, in: context.source.baseURL), let number = Int(chapter.id.externalID), number > 0, number != 404 else { throw MangaError.invalidURL }
        let value = try await comic(number, context: context)
        guard let image = resolvedWebURL(value.img, relativeTo: context.source.baseURL), image.scheme == "https", image.host == "imgs.xkcd.com" else { throw MangaError.parseMismatch("xkcd 正文地址无效") }
        return [PageResource(id: PageID(chapterID: chapter.id, externalID: "1"), ordinal: 0, request: ResourceRequest(url: image, referer: chapter.url))]
    }
}
