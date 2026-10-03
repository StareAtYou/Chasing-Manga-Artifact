import Foundation
public enum BuiltinSources {
    public static func candidates() -> [Source] {
        zip(["漫画站", "瓜子漫画", "DM5", "MangaDex", "xkcd（英文原创）", "包子漫画（org）"], ["https://www.manhuazhan.com/", "https://www.guazimanhua.com/", "https://www.dm5.com/", "https://mangadex.org/", "https://xkcd.com/", "https://baozimh.org/"]).enumerated().map { index, value in
            Source(id: SourceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000010\(index)")!), name: value.0, baseURL: URL(string: value.1)!)
        }
    }
    public static func adapters() -> [any SourceAdapter] { [GuaziAdapter(), DM5Adapter(), ManhuazhanAdapter(), MangaDexAdapter(), XKCDAdapter(), BaoziAdapter(), HTMLTemplateAdapter(), JSONTemplateAdapter()] }
    public static func candidateAdapter(for source: Source) -> (any SourceAdapter)? {
        switch source.baseURL.host?.lowercased() {
        case "www.guazimanhua.com": GuaziAdapter()
        case "www.dm5.com": DM5Adapter()
        case "www.manhuazhan.com": ManhuazhanAdapter()
        case "mangadex.org", "www.mangadex.org": MangaDexAdapter()
        case "xkcd.com", "www.xkcd.com": XKCDAdapter()
        case "baozimh.org": BaoziAdapter()
        default: nil
        }
    }
}
