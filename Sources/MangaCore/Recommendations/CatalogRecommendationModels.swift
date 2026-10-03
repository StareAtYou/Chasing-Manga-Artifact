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
    private static let english:[String:String]=["action":"热血","adventure":"冒险","romance":"恋爱","school life":"校园","science fiction":"科幻","sci-fi":"科幻","slice of life":"日常","comedy":"搞笑","gag-a-day":"搞笑","fantasy":"奇幻","horror":"恐怖","mystery":"悬疑","sports":"运动","historical":"历史","magic":"魔法","drama":"剧情","supernatural":"灵异","psychological":"心理","thriller":"惊悚","animals":"动物","animal":"动物","real life":"日常"]
    public static func normalized(_ title:String) -> String {
        let clean=title.trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:"#")))
        return english[clean.lowercased()] ?? clean.applyingTransform(StringTransform(rawValue:"Traditional-Simplified"),reverse:false) ?? clean
    }
    static func known(_ title:String) -> Bool {
        let genres:Set<String>=["热血","冒险","恋爱","校园","科幻","生活","日常","搞笑","奇幻","恐怖","悬疑","运动","历史","魔法","剧情","灵异","心理","惊悚","战争","古风","玄幻","穿越","都市","修仙","战斗","纯爱","治愈","重生","异能","后宫","百合","彩虹","神鬼","大女主","系统","复仇","逆袭","欧美","国漫","日漫","韩漫","原创"]
        return genres.contains(normalized(title))
    }
}
