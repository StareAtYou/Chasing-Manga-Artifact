import Foundation
import SwiftSoup
/// Extract only source-owned navigation and explicitly labelled popular blocks.
/// No code from the site is executed and ordinary update lists never become ranks.
public enum HTMLCatalogDiscovery {
    private static let headingSelector="h1,h2,h3,h4,.list-con-title,.index-rank-title,.rank-title,.index-title"
    private static func popular(_ text:String) -> Bool {
        let text=CatalogTaxonomy.normalized(text).lowercased()
        return ["排行","人气","热度","热门推荐","popular","most read","most viewed"].contains(where:text.contains)
    }
    private static func identity(_ url:URL) -> String {
        var c=URLComponents(url:url,resolvingAgainstBaseURL:false)!
        c.fragment=nil;c.queryItems=c.queryItems?.filter {!["from","ref"].contains($0.name) && !$0.name.hasPrefix("utm_")}.sorted{$0.name < $1.name}
        if c.queryItems?.isEmpty==true {c.queryItems=nil}
        if c.path != "/",c.path.hasSuffix("/") {c.path.removeLast()}
        return c.string ?? url.absoluteString
    }
    static func catalogContext(_ context: ParserContext) -> ParserContext {
        ParserContext(source: context.source, client: CatalogDocumentClient(client: context.client), renderer: context.renderer)
    }
    static func sameDocument(_ requested: URL, _ final: URL) -> Bool { identity(requested) == identity(final) }
    private static func navigationURL(_ link:Element,base:URL) throws -> URL? {
        let href=try link.attr("href")
        if let url = resolvedWebURL(href,relativeTo:base) { return url }
        return resolvedWebURL(try link.attr("data-url"),relativeTo:base)
    }
    private static func genres(_ doc:Document,base:URL,source:Source,works:[SourceWork]) throws -> [CatalogChannel] {
        let workURLs=Set(works.map {identity($0.url)})
        var channels:[CatalogChannel]=[];var seen=Set<String>()
        for link in try doc.select("a[href],a[data-url]").array() {
            let title=try link.text().trimmingCharacters(in:.whitespacesAndNewlines)
            guard !title.isEmpty,title.count <= 40,!["全部","全部分类","全部类型","全部漫画","漫画大全"].contains(CatalogTaxonomy.normalized(title)),let url=try navigationURL(link,base:base),SourceScope.contains(url,in:source.baseURL),!workURLs.contains(identity(url)),url != source.baseURL else {continue}
            let genrePath=["/manga-list-","/manga-genre/","/manga-tag/","/genre/","/category/","/tag/","/type/"].contains(where:url.path.contains)
            let isTag=(url.path=="/search.php" && URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.contains(where:{$0.name=="combinedquery" && $0.value?.hasPrefix("#")==true})==true)
            let knownCategoryPath=genrePath || isTag || url.path.contains("/manhua-") || url.path.contains("category.php") || url.path.contains("type.php")
            let category=knownCategoryPath && (CatalogTaxonomy.known(title) || genrePath || isTag)
            guard category || popular(title) else {continue}
            let kind:CatalogChannelKind=popular(title) && !CatalogTaxonomy.known(title) ? .popular : .genre
            let key=url.absoluteString
            guard seen.insert(key).inserted else {continue}
            let sorts:[CatalogSort]=source.baseURL.host=="www.mangabz.com" || source.baseURL.host=="comicfury.com" ? [.sourceDefault,.popularity,.latest] : [.sourceDefault]
            channels.append(CatalogChannel(id:key,title:title,url:url,kind:kind,genre:kind == .genre ? CatalogTaxonomy.normalized(title) : nil,sorts:sorts))
        }
        return channels
    }
    private static func rankedSections(_ doc:Document,base:URL,source:Source,works:[SourceWork]) throws -> [CatalogSection] {
        var byURL:[String:SourceWork]=[:];for work in works {byURL[identity(work.url)]=work}
        var sections:[CatalogSection]=[];var titles=Set<String>()
        for heading in try doc.select(headingSelector).array() {
            let title=try heading.text().trimmingCharacters(in:.whitespacesAndNewlines)
            guard popular(title),title.count<=60,!titles.contains(title) else {continue}
            var parent=heading.parent()
            for _ in 0..<5 {
                guard let scope=parent,!["body","html"].contains(scope.tagName()) else {break}
                var ranked:[SourceWork]=[];var seen=Set<SourceWorkID>()
                for link in try scope.select("a[href]").array() {
                    if let url=try navigationURL(link,base:base),let work=byURL[identity(url)],seen.insert(work.id).inserted {ranked.append(work)}
                }
                let otherHeadings=try scope.select(headingSelector).array().filter {element in
                    let value=try element.text()
                    return element !== heading && (popular(value) || ["最新","更新","上架"].contains(where:value.contains))
                }
                if !ranked.isEmpty,ranked.count<=80,otherHeadings.isEmpty {
                    let channel=CatalogChannel(id:"section:"+title,title:title,url:source.baseURL,kind:.popular)
                    sections.append(CatalogSection(channel:channel,works:ranked));titles.insert(title);break
                }
                parent=scope.parent()
            }
        }
        return sections
    }
    public static func recommendations(adapter:any SourceAdapter,context:ParserContext,rootURL:URL?=nil) async throws -> SourceRecommendations {
        let root=rootURL ?? context.source.baseURL
        let rootChannel=CatalogChannel(id:"browse",title:"来源浏览",url:root,kind:.browse)
        let works=try await adapter.catalogPage(channel:rootChannel,sort:.sourceDefault,pageURL:nil,context:context).works.filter{$0.id.sourceID==context.source.id && SourceScope.contains($0.url,in:context.source.baseURL)}
        let doc=try SwiftSoup.parse(await context.text(root),root.absoluteString);try HTMLAccessGuard.check(doc)
        var notices:[String]=[]
        var channels=try genres(doc,base:root,source:context.source,works:works)
        // Homepage menus are often incomplete. Follow one actual "all categories"
        // link rather than inventing taxonomy from manga titles or summaries.
        let allLabels:Set<String>=["全部分类","全部类型","全部漫画","漫画大全"]
        if let all=try doc.select("a[href]").array().first(where:{allLabels.contains(CatalogTaxonomy.normalized(try $0.text()))}),let url=try navigationURL(all,base:root),url != root,SourceScope.contains(url,in:context.source.baseURL) {
            do {
                let taxonomy=try SwiftSoup.parse(await context.text(url),url.absoluteString);try HTMLAccessGuard.check(taxonomy)
                let more=try genres(taxonomy,base:url,source:context.source,works:works)
                var seen=Set(channels.map(\.id));channels += more.filter {seen.insert($0.id).inserted}
            } catch is CancellationError {throw CancellationError()} catch { notices.append("完整分类暂未加载，已保留首页分类。") }
        }
        var sections=try rankedSections(doc,base:root,source:context.source,works:works)
        if context.source.baseURL.host=="comicfury.com",let popularity=try doc.select("a[data-url]").array().first(where:{try $0.text().trimmingCharacters(in:.whitespacesAndNewlines)=="Popularity"}),let url=try navigationURL(popularity,base:root),SourceScope.contains(url,in:context.source.baseURL) {
            let channel=CatalogChannel(id:url.absoluteString,title:"关注人气榜",url:url,kind:.popular,sorts:[.sourceDefault])
            do {let page=try await adapter.catalogPage(channel:channel,sort:.sourceDefault,pageURL:nil,context:context);if !page.works.isEmpty {sections.append(CatalogSection(channel:channel,works:page.works));channels.removeAll{$0.id==channel.id};channels.append(channel)}}
            catch is CancellationError {throw CancellationError()} catch { notices.append("人气榜暂未加载，已保留来源浏览内容。") }
        }
        sections.append(CatalogSection(channel:rootChannel,works:works))
        var seen=Set(channels.map(\.id));for section in sections where seen.insert(section.channel.id).inserted {channels.append(section.channel)}
        return SourceRecommendations(source:context.source,channels:channels,sections:sections,notices:notices)
    }
    public static func sortedURL(_ channel:CatalogChannel,sort:CatalogSort,source:Source) throws -> URL {
        guard channel.sorts.contains(sort),SourceScope.contains(channel.url,in:source.baseURL) else {throw MangaError.invalidURL}
        if source.baseURL.host=="www.mangabz.com",sort != .sourceDefault {
            guard let parts=DM5ReaderData.captures(#"^/manga-list-(\d+)-(\d+)-\d+/?$"#,in:channel.url.path) else {return channel.url}
            return source.baseURL.appendingPathComponent("manga-list-"+parts[0]+"-"+parts[1]+"-"+(sort == .popularity ? "10" : "2")+"/")
        }
        if source.baseURL.host=="comicfury.com",sort != .sourceDefault {
            var c=URLComponents(url:channel.url,resolvingAgainstBaseURL:false)!
            c.queryItems=(c.queryItems ?? []).filter{$0.name != "sort"}+[URLQueryItem(name:"sort",value:sort == .popularity ? "1" : "2")]
            return c.url!
        }
        return channel.url
    }
    private static func family(_ url:URL) -> String {
        var c=URLComponents(url:url,resolvingAgainstBaseURL:false)!
        c.fragment=nil
        c.path=c.path.replacingOccurrences(of:#"-p\d+(?=/|$)|/page/\d+/?$"#,with:"",options:.regularExpression)
        c.queryItems=c.queryItems?.filter{!["page","p","pageindex","offset"].contains($0.name.lowercased())}.sorted{$0.name < $1.name}
        if c.queryItems?.isEmpty==true {c.queryItems=nil}
        return c.string ?? url.absoluteString
    }
    public static func page(html:String,works:[SourceWork],url:URL,source:Source) throws -> CatalogPage {
        let doc=try SwiftSoup.parse(html,url.absoluteString);try HTMLAccessGuard.check(doc)
        var next:URL?
        for link in try doc.select("a[href],a[data-url]").array() {
            let title=CatalogTaxonomy.normalized(try link.text()).lowercased()
            let hint=CatalogTaxonomy.normalized(try link.attr("title")).lowercased()
            let rel=try link.attr("rel").lowercased()
            guard rel.split(separator:" ").contains("next") || ["下一页","next","next page","next >",">","›","»"].contains(title) || ["下一页","next","next page"].contains(hint) else {continue}
            guard let candidate=try navigationURL(link,base:url),candidate != url,SourceScope.contains(candidate,in:source.baseURL),family(candidate)==family(url) else {continue}
            next=candidate;break
        }
        var seen=Set<SourceWorkID>()
        return CatalogPage(works:works.filter{$0.id.sourceID==source.id && SourceScope.contains($0.url,in:source.baseURL) && seen.insert($0.id).inserted},nextURL:next)
    }
}

// Scope alone cannot distinguish two categories on the same website.
private struct CatalogDocumentClient: HTTPClient {
    let client: any HTTPClient
    func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        let response = try await client.send(request, sourceID: sourceID, priority: priority)
        guard HTMLCatalogDiscovery.sameDocument(request.url, response.finalURL) else { throw MangaError.parseMismatch("专栏跳转到了不同的分类、排序或页码，请刷新来源后重试") }
        return response
    }
}
