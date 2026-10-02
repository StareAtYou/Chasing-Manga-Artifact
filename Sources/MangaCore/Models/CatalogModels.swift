import Foundation
public struct Work: Codable, Hashable, Sendable, Identifiable {
    public let id: WorkID
    public var title: String
    public var coverURL: URL?
    public var preferredSourceWorkID: SourceWorkID?
    public var addedAt: Date
    public init(id: WorkID = WorkID(), title: String, coverURL: URL? = nil, preferredSourceWorkID: SourceWorkID? = nil) {
        self.id = id; self.title = title; self.coverURL = coverURL; self.preferredSourceWorkID = preferredSourceWorkID; addedAt = Date()
    }
}
public struct SourceWork: Codable, Hashable, Sendable, Identifiable {
    public let id: SourceWorkID
    public var title: String
    public var url: URL
    public var coverURL: URL?
    public var author: String
    public var aliases: [String]
    public var summary: String
    public var latestChapter: String
    public var checkedAt: Date?
    public var capabilities: SourceCapabilities
    public init(id: SourceWorkID, title: String, url: URL, coverURL: URL? = nil, author: String = "", aliases: [String] = [], summary: String = "", latestChapter: String = "", capabilities: SourceCapabilities = []) {
        self.id = id; self.title = title; self.url = url; self.coverURL = coverURL; self.author = author; self.aliases = aliases; self.summary = summary; self.latestChapter = latestChapter; self.capabilities = capabilities
    }
}
public enum ChapterAccess: String, Codable, Sendable { case available, login, paid, restricted }
public struct Chapter: Codable, Hashable, Sendable, Identifiable {
    public let id: ChapterID
    public var title: String
    public var url: URL
    public var ordinal: Int
    public var access: ChapterAccess
    public init(id: ChapterID, title: String, url: URL, ordinal: Int, access: ChapterAccess = .available) {
        self.id = id; self.title = title; self.url = url; self.ordinal = ordinal; self.access = access
    }
}
