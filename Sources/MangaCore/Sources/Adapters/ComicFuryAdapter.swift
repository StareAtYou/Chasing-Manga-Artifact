import Foundation
import SwiftSoup

/// Public creator-hosted comics through ComicFury's same-origin archive and viewer.
public struct ComicFuryAdapter: SourceAdapter {
    public let id = "comicfury-reader"
    public let version = 1
    public let capabilities: SourceCapabilities = [.browse, .search, .readable]
    public init() { }
    private let archivePageLimit = 1_000

    private func validateSource(_ context: ParserContext) throws {
        let base = context.source.baseURL
        guard base.scheme == "https", base.host == "comicfury.com", base.port == nil || base.port == 443,
              base.path == "/" || base.path.isEmpty, base.query == nil, base.fragment == nil,
              SourceScope.contains(base, in: base) else { throw MangaError.invalidURL }
    }

    private func document(_ url: URL, context: ParserContext) async throws -> Document {
        try validateSource(context)
        guard SourceScope.contains(url, in: context.source.baseURL) else { throw MangaError.invalidURL }
        let response = try await context.client.send(ResourceRequest(url: url), sourceID: context.source.id, priority: .reading)
        guard SourceScope.contains(response.finalURL, in: context.source.baseURL) else {
            throw MangaError.unsupported("ComicFury 页面跳转到了其他来源")
        }
        let doc = try SwiftSoup.parse(response.text, response.finalURL.absoluteString)
        try HTMLAccessGuard.check(doc)
        guard semanticID(response.finalURL) == semanticID(url) else { throw MangaError.parseMismatch("ComicFury 页面地址与请求不匹配") }
        return doc
    }

    private func validSlug(_ slug: String) -> Bool {
        slug.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }

    private func profileSlug(_ url: URL, context: ParserContext) -> String? {
        guard SourceScope.contains(url, in: context.source.baseURL), url.path == "/comicprofile.php", url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 1, items[0].name == "url", let slug = items[0].value, validSlug(slug) else { return nil }
        return slug
    }

    private func profileURL(_ slug: String, context: ParserContext) -> URL {
        var components = URLComponents(url: context.source.baseURL.appendingPathComponent("comicprofile.php"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "url", value: slug)]
        return components.url!
    }

    private func listing(_ url: URL, context: ParserContext) async throws -> [SourceWork] {
        let doc = try await document(url, context: context)
        guard try doc.select(".webcomic-results").first() != nil else { throw MangaError.parseMismatch("ComicFury 搜索结构不匹配") }
        var result: [SourceWork] = []; var seen = Set<String>()
        for item in try doc.select(".webcomic-result").array() {
            guard let link = try item.select(".webcomic-result-title a[href]").first(),
                  let workURL = resolvedWebURL(try link.attr("href"), relativeTo: url),
                  let slug = profileSlug(workURL, context: context) else { continue }
            let title = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seen.insert(slug).inserted else { continue }
            let image = try item.select(".webcomic-result-avatar img").first()
            let cover = try image.flatMap { resolvedWebURL(try $0.attr("src"), relativeTo: url) }
            result.append(SourceWork(id: SourceWorkID(sourceID: context.source.id, externalID: slug), title: title,
                                     url: profileURL(slug, context: context), coverURL: cover, capabilities: capabilities))
        }
        return result
    }

    public func recommendations(context: ParserContext) async throws -> SourceRecommendations {
        try await HTMLCatalogDiscovery.recommendations(adapter: self, context: context, rootURL: context.source.baseURL.appendingPathComponent("search.php"))
    }
    public func catalogPage(channel: CatalogChannel, sort: CatalogSort, pageURL: URL?, context: ParserContext) async throws -> CatalogPage {
        let url: URL
        if let pageURL { url = pageURL } else { url = try HTMLCatalogDiscovery.sortedURL(channel, sort: sort, source: context.source) }
        guard SourceScope.contains(url, in: context.source.baseURL) else { throw MangaError.invalidURL }
        let works = try await listing(url, context: context)
        return try HTMLCatalogDiscovery.page(html: await context.text(url), works: works, url: url, source: context.source)
    }
    public func browse(context: ParserContext) async throws -> [SourceWork] {
        try await listing(context.source.baseURL.appendingPathComponent("search.php"), context: context)
    }

    public func search(query: String, context: ParserContext) async throws -> [SourceWork] {
        try validateSource(context)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var components = URLComponents(url: context.source.baseURL.appendingPathComponent("search.php"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "vr", value: "1"), URLQueryItem(name: "combinedquery", value: query)]
        return try await listing(components.url!, context: context)
    }

    public func details(url: URL, context: ParserContext) async throws -> SourceWork {
        try validateSource(context)
        guard let slug = profileSlug(url, context: context) else { throw MangaError.invalidURL }
        let doc = try await document(url, context: context)
        let title = try doc.select(".profileinfobox .username-and-title .authorname").first()?.text() ?? ""
        let archivePath = "/read/\(slug)/archive"
        let hasArchive = try doc.select(".profileinfobox a[href]").array().contains {
            guard let link = resolvedWebURL(try $0.attr("href"), relativeTo: url) else { return false }
            return SourceScope.contains(link, in: context.source.baseURL) && link.path == archivePath && link.query == nil && link.fragment == nil
        }
        guard !title.isEmpty, hasArchive else { throw MangaError.parseMismatch("ComicFury 作品资料不匹配") }
        var summary = ""; var authors: [String] = []
        for category in try doc.select(".profilecategory").array() {
            let heading = try category.select(".pchead").first()?.text().lowercased() ?? ""
            if heading == "webcomic description", let content = try category.select(".pccontent").first() {
                try content.select(".description-tags").remove()
                summary = try content.text()
            } else if heading == "authors" {
                authors = try category.select("a.authorname").array().map { try $0.text() }
            }
        }
        let cover = try doc.select(".profileinfobox .profile-avatar img").first().flatMap { resolvedWebURL(try $0.attr("src"), relativeTo: url) }
        return SourceWork(id: SourceWorkID(sourceID: context.source.id, externalID: slug), title: title,
                          url: profileURL(slug, context: context), coverURL: cover, author: authors.joined(separator: " / "),
                          summary: summary, capabilities: capabilities)
    }

    private func chapterNumber(_ url: URL, slug: String, context: ParserContext) -> String? {
        guard SourceScope.contains(url, in: context.source.baseURL), url.query == nil, url.fragment == nil else { return nil }
        let prefix = "/read/\(slug)/comics/"
        guard url.path.hasPrefix(prefix) else { return nil }
        let number = String(url.path.dropFirst(prefix.count))
        guard number.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression) != nil else { return nil }
        return number
    }

    private func archivePage(_ url: URL, slug: String, context: ParserContext) -> Int? {
        guard SourceScope.contains(url, in: context.source.baseURL), url.query == nil, url.fragment == nil else { return nil }
        let path = "/read/\(slug)/archive"
        if url.path == path { return 1 }
        guard url.path.hasPrefix(path + "/page/") else { return nil }
        let number = String(url.path.dropFirst((path + "/page/").count))
        guard number.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression) != nil,
              let page = Int(number), page <= archivePageLimit else { return nil }
        return page
    }

    public func chapters(work: SourceWork, context: ParserContext) async throws -> [Chapter] {
        try validateSource(context)
        guard work.id.sourceID == context.source.id, let slug = profileSlug(work.url, context: context),
              work.id.externalID == slug else { throw MangaError.invalidURL }
        let archive = context.source.baseURL.appendingPathComponent("read/\(slug)/archive")
        var page = 1; var lastPage = 1; var seen = Set<String>(); var chapters: [Chapter] = []
        while page <= lastPage {
            let url = page == 1 ? archive : archive.appendingPathComponent("page/\(page)")
            let doc = try await document(url, context: context)
            guard try doc.select(".archive-comics").first() != nil else { throw MangaError.parseMismatch("ComicFury 目录结构不匹配") }
            let pagination = try doc.select("a.vfpage[href]").array()
            if !pagination.isEmpty || page > 1 {
                guard let current = try doc.select(".vfpagecurrent").first()?.text(), Int(current) == page else {
                    throw MangaError.parseMismatch("ComicFury 目录分页重复或不完整")
                }
            }
            for link in pagination {
                guard let nextURL = resolvedWebURL(try link.attr("href"), relativeTo: url),
                      let nextPage = archivePage(nextURL, slug: slug, context: context) else {
                    throw MangaError.parseMismatch("ComicFury 目录分页地址无效或超出限制")
                }
                lastPage = max(lastPage, nextPage)
            }
            let startCount = chapters.count
            for link in try doc.select(".archive-comics a[href]").array() {
                guard let chapterURL = resolvedWebURL(try link.attr("href"), relativeTo: url),
                      let number = chapterNumber(chapterURL, slug: slug, context: context) else { continue }
                let title = try link.select(".archive-comic-title").first()?.text() ?? ""
                guard !title.isEmpty, seen.insert(number).inserted else { throw MangaError.parseMismatch("ComicFury 目录章节重复或缺少标题") }
                chapters.append(Chapter(id: ChapterID(sourceWorkID: work.id, externalID: number), title: title,
                                        url: chapterURL, ordinal: chapters.count))
            }
            guard chapters.count > startCount else { throw MangaError.parseMismatch("ComicFury 目录页为空，无法确认完整目录") }
            page += 1
        }
        return chapters
    }

    public func pages(chapter: Chapter, context: ParserContext) async throws -> [PageResource] {
        try validateSource(context)
        let workID = chapter.id.sourceWorkID
        guard workID.sourceID == context.source.id, validSlug(workID.externalID),
              let number = chapterNumber(chapter.url, slug: workID.externalID, context: context),
              chapter.id.externalID == number else { throw MangaError.invalidURL }
        let doc = try await document(chapter.url, context: context)
        let comics = try doc.select(".is--comic-page[data-comicid='\(number)']").array()
        guard comics.count == 1 else { throw MangaError.parseMismatch("ComicFury 正文章节与请求不匹配") }
        if try comics[0].select(".is--comic-content .is--unsupported-notice").first() != nil {
            throw MangaError.unsupported("此章的媒体格式仅支持在原站阅读")
        }
        let images = try comics[0].select(".is--comic-content .is--image-segment img").array()
        guard !images.isEmpty else { throw MangaError.parseMismatch("ComicFury 未返回正文图片") }
        return try images.enumerated().map { index, image in
            guard let imageURL = resolvedWebURL(try image.attr("src"), relativeTo: chapter.url),
                  imageURL.scheme == "https", imageURL.host == "img.comicfury.com", imageURL.port == nil || imageURL.port == 443,
                  SourceScope.contains(imageURL, in: URL(string: "https://img.comicfury.com/comics/")!),
                  imageURL.path != "/comics/" else { throw MangaError.parseMismatch("ComicFury 正文图片地址无效") }
            return PageResource(id: PageID(chapterID: chapter.id, externalID: String(index + 1)), ordinal: index,
                                request: ResourceRequest(url: imageURL, referer: chapter.url))
        }
    }
}
