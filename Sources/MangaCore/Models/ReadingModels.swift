import Foundation
public struct PageResource: Codable, Hashable, Sendable, Identifiable {
    public let id: PageID
    public var ordinal: Int
    public var request: ResourceRequest
    public var expiresAt: Date?
    public init(id: PageID, ordinal: Int, request: ResourceRequest, expiresAt: Date? = nil) {
        self.id = id; self.ordinal = ordinal; self.request = request; self.expiresAt = expiresAt
    }
}
public struct ReadingProgress: Codable, Hashable, Sendable {
    public var chapterID: ChapterID
    public var pageID: PageID
    public var fraction: Double
    public var updatedAt: Date
    public var sourceWorkID: SourceWorkID { chapterID.sourceWorkID }
    public init(chapterID: ChapterID, pageID: PageID, fraction: Double = 0) {
        self.chapterID = chapterID; self.pageID = pageID; self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0; updatedAt = Date()
    }
}
public enum ReadingMode: String, Codable, CaseIterable, Sendable { case scroll, paged, doublePage }
public enum ReadingDirection: String, Codable, CaseIterable, Sendable { case leftToRight, rightToLeft }
public enum AppTheme: String, Codable, CaseIterable, Sendable { case system, light, dark }
public struct ReaderPreferences: Codable, Hashable, Sendable {
    public var mode: ReadingMode = .scroll
    public var direction: ReadingDirection = .leftToRight
    public var background: AppTheme = .system
    public init() {}
}
public struct UserSettings: Codable, Sendable {
    public var theme: AppTheme = .system
    public var notifications: Bool = false
    public var decodedCacheBytes: Int = 64 * 1024 * 1024
    public var diskCacheBytes: Int = 256 * 1024 * 1024
    public init() {}
}
