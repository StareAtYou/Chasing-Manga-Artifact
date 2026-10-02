import Foundation
import MangaCore
public enum Samples {
    public static let sourceA = Source(id: SourceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), name: "Source A", baseURL: URL(string: "https://a.test/")!)
    public static let sourceB = Source(id: SourceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!), name: "Source B", baseURL: URL(string: "https://b.test/")!)
    public static func work(_ source: Source = sourceA, externalID: String = "42") -> SourceWork {
        SourceWork(id: SourceWorkID(sourceID: source.id, externalID: externalID), title: "测试漫画", url: source.baseURL.appendingPathComponent("comic/" + externalID), author: "作者")
    }
    public static func chapter(_ work: SourceWork, externalID: String = "1", ordinal: Int = 0) -> Chapter {
        Chapter(id: ChapterID(sourceWorkID: work.id, externalID: externalID), title: "第\(externalID)话", url: work.url.appendingPathComponent(externalID), ordinal: ordinal)
    }
    public static func pages(_ chapter: Chapter, count: Int = 2) -> [PageResource] {
        (0..<count).map { PageResource(id: PageID(chapterID: chapter.id, externalID: String($0 + 1)), ordinal: $0, request: ResourceRequest(url: URL(string: "https://images.test/\($0 + 1).png")!)) }
    }
    public static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
}
