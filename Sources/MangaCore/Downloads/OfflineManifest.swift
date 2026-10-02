import Foundation
import CryptoKit
public enum ContentDigest {
    public static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func filename(_ pageID: PageID) -> String { hex(Data(pageID.key.utf8)) + ".image" }
}
public struct OfflineEntry: Codable, Sendable {
    public let pageID: PageID
    public let ordinal: Int
    public let filename: String
    public let digest: String
    public let bytes: Int
    public init(pageID: PageID, ordinal: Int, filename: String, digest: String, bytes: Int) { self.pageID = pageID; self.ordinal = ordinal; self.filename = filename; self.digest = digest; self.bytes = bytes }
}
public struct OfflineManifest: Codable, Sendable {
    public let taskID: UUID
    public let chapterID: ChapterID
    public var entries: [OfflineEntry] = []
    public init(taskID: UUID, chapterID: ChapterID) { self.taskID = taskID; self.chapterID = chapterID }
}
