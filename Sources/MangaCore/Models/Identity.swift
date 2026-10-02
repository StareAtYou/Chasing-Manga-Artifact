import Foundation
public enum SourceTag: Sendable {}
public enum WorkTag: Sendable {}
public struct EntityID<Tag>: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
    public var key: String { description }
}
public typealias SourceID = EntityID<SourceTag>
public typealias WorkID = EntityID<WorkTag>
public struct SourceWorkID: Hashable, Codable, Sendable {
    public let sourceID: SourceID
    public let externalID: String
    public init(sourceID: SourceID, externalID: String) { self.sourceID = sourceID; self.externalID = externalID }
    public var key: String { sourceID.key + ":" + Data(externalID.utf8).base64EncodedString() }
}
public struct ChapterID: Hashable, Codable, Sendable {
    public let sourceWorkID: SourceWorkID
    public let externalID: String
    public init(sourceWorkID: SourceWorkID, externalID: String) { self.sourceWorkID = sourceWorkID; self.externalID = externalID }
    public var key: String { sourceWorkID.key + ":" + Data(externalID.utf8).base64EncodedString() }
}
public struct PageID: Hashable, Codable, Sendable {
    public let chapterID: ChapterID
    public let externalID: String
    public init(chapterID: ChapterID, externalID: String) { self.chapterID = chapterID; self.externalID = externalID }
    public var key: String { chapterID.key + ":" + Data(externalID.utf8).base64EncodedString() }
}
public func canonicalSourceURL(_ url: URL) throws -> URL {
    guard var c = URLComponents(url: url, resolvingAgainstBaseURL: true),
          let scheme = c.scheme?.lowercased(), ["https", "http"].contains(scheme),
          let host = c.host, !host.isEmpty, c.user == nil, c.password == nil else { throw MangaError.invalidURL }
    c.scheme = scheme; c.host = host.lowercased(); c.fragment = nil
    if (scheme == "https" && c.port == 443) || (scheme == "http" && c.port == 80) { c.port = nil }
    if c.path.isEmpty { c.path = "/" }
    guard let result = c.url else { throw MangaError.invalidURL }; return result
}
