import Foundation
public enum CatalogChannelKind:String,Codable,Sendable {case popular,genre,browse,series}
public enum CatalogSort:String,Codable,CaseIterable,Sendable {case sourceDefault,popularity,latest
    public var title:String {switch self {case .sourceDefault:"原站顺序";case .popularity:"人气";case .latest:"最新更新"}}
}
public struct CatalogChannel:Codable,Hashable,Sendable,Identifiable {
    public var id:String
    public var title:String
    public var url:URL
    public var kind:CatalogChannelKind
    public var genre:String?
    public var sorts:[CatalogSort]
    public init(id:String,title:String,url:URL,kind:CatalogChannelKind,genre:String?=nil,sorts:[CatalogSort]=[.sourceDefault]) {
        self.id=id;self.title=title;self.url=url;self.kind=kind;self.genre=genre;self.sorts=sorts
    }
}
public struct CatalogPage:Codable,Sendable {
    public var works:[SourceWork]
    public var nextURL:URL?
    public init(works:[SourceWork],nextURL:URL?=nil) {self.works=works;self.nextURL=nextURL}
}
public struct CatalogSection:Codable,Sendable,Identifiable {
    public var channel:CatalogChannel
    public var works:[SourceWork]
    public var id:String {channel.id}
    public init(channel:CatalogChannel,works:[SourceWork]) {self.channel=channel;self.works=works}
}
public struct SourceRecommendations:Codable,Sendable {
    public var sourceID:SourceID
    public var sourceRevision:Int
    public var channels:[CatalogChannel]
    public var sections:[CatalogSection]
    public var notices:[String]
    public var fetchedAt:Date
    public init(source:Source,channels:[CatalogChannel],sections:[CatalogSection],fetchedAt:Date=Date(),notices:[String]=[]) {
        sourceID=source.id;sourceRevision=source.revision;self.channels=channels;self.sections=sections;self.fetchedAt=fetchedAt;self.notices=notices
    }
}
public enum CatalogTaxonomy {
    private static let english:[String:String]=["action":"热血","adventure":"冒险","romance":"恋爱","school life":"校园","science fiction":"科幻","sci-fi":"科幻","slice of life":"日常","comedy":"搞笑","gag-a-day":"搞笑","fantasy":"奇幻","horror":"恐怖","mystery":"悬疑","sports":"运动","historical":"历史","magic":"魔法","drama":"剧情","supernatural":"灵异","psychological":"心理","thriller":"惊悚","animals":"动物","animal":"动物","real life":"日常","mecha":"机甲","boys' love":"耽美","girls' love":"百合","crime":"犯罪","superhero":"超级英雄","magical girls":"魔法少女","wuxia":"武侠","isekai":"异世界","philosophical":"哲思","medical":"医疗","tragedy":"悲剧","fan fiction":"同人","furry/anthro":"拟兽","cats":"猫咪","surreal":"超现实","lgbtq+":"多元性别","pokémon":"宝可梦","sciencefiction":"科幻","fanfiction":"同人","gagaday":"搞笑","furryanthro":"拟兽","reallife":"日常","lgbtq":"多元性别","pokemon":"宝可梦"]
    public static func normalized(_ title:String) -> String {
        let clean=title.trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:"#")))
        return english[clean.lowercased()] ?? clean.applyingTransform(StringTransform(rawValue:"Traditional-Simplified"),reverse:false) ?? clean
    }
    /// A category URL alone does not make a link a category. Keep legitimate
    /// source-specific labels, but reject navigation, status and sorting controls.
    public static func genreName(_ title: String) -> String? {
        let name = normalized(title)
        guard !name.isEmpty, name.count <= 40, name.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return nil }
        let controls: Set<String> = ["全部", "全部分类", "全部类型", "全部漫画", "漫画大全", "首页", "末页", "尾页", "返回", "更多", "查看更多", "展开", "收起", "分类", "状态", "排序", "连载", "连载中", "完结", "已完结", "已完成", "最新", "最近更新", "更新时间", "更新日期", "人气", "热度", "热门", "热门漫画", "热门推荐", "人气排行", "热度排行", "评分", "搜索", "筛选", "all", "next", "previous", "prev", "first", "last", "home", "more", "show more", "load more", "ongoing", "completed", "complete", "latest", "last update", "last updated", "popularity", "popular", "sort", "status"]
        let lower = name.lowercased()
        guard !controls.contains(lower), !["下一页", "上一页", "下一章", "上一章", "next page", "previous page", "prev page"].contains(where: lower.contains), lower.range(of: #"^(?:page|第)\s*\d+(?:\s*页)?$"#, options: .regularExpression) == nil else { return nil }
        return name
    }
    static func isPaginationURL(_ url: URL) -> Bool {
        if url.path.range(of: #"-p\d+(?=/|$)|/page/\d+/?$"#, options: .regularExpression) != nil { return true }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { item in
            guard let number = Int(item.value ?? "") else { return false }
            return (["page", "p", "pageindex"].contains(item.name.lowercased()) && number > 1) || (item.name.lowercased() == "offset" && number > 0)
        } == true
    }
    public static func cleaned(_ snapshot: SourceRecommendations) -> SourceRecommendations {
        var result = snapshot
        var genres = Set<String>(), ids = Set<String>()
        result.channels = snapshot.channels.compactMap { original in
            var channel = original
            if channel.kind == .genre {
                guard !isPaginationURL(channel.url) else { return nil }
                var name = genreName(channel.genre ?? channel.title)
                // Older ComicFury snapshots used the '+' add control as a title.
                // Its single declared tag query is enough to recover the tag.
                if name == nil, channel.url.host == "comicfury.com", channel.url.path == "/search.php", let tag = URLComponents(url: channel.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "combinedquery" })?.value, tag.hasPrefix("#"), !tag.dropFirst().contains("#") {
                    name = genreName(tag)
                }
                guard let name, genres.insert(name).inserted else { return nil }
                channel.genre = name; channel.title = name
            }
            guard ids.insert(channel.id).inserted else { return nil }
            return channel
        }
        let channels = Dictionary(uniqueKeysWithValues: result.channels.map { ($0.id, $0) })
        result.sections = snapshot.sections.compactMap { section in
            guard let channel = channels[section.channel.id] else { return nil }
            return CatalogSection(channel: channel, works: section.works)
        }
        return result
    }
    static func known(_ title:String) -> Bool {
        let genres:Set<String>=["热血","冒险","恋爱","校园","科幻","生活","日常","搞笑","奇幻","恐怖","悬疑","运动","历史","魔法","剧情","灵异","心理","惊悚","战争","古风","玄幻","穿越","都市","修仙","战斗","纯爱","治愈","重生","异能","后宫","百合","彩虹","神鬼","大女主","系统","复仇","逆袭","欧美","国漫","日漫","韩漫","原创"]
        return genres.contains(normalized(title))
    }
}
