import Foundation
public enum DownloadState: String, Codable, Sendable { case queued, running, paused, failed, completed, cancelled }
public struct DownloadTask: Codable, Sendable, Identifiable {
    public let id: UUID
    public let chapter: Chapter
    public var pages: [PageResource]
    public let sourceSnapshot: Source?
    public var state: DownloadState = .queued
    public var completedPages = 0
    public var bytes = 0
    public var error: MangaError?
    public var generation = UUID()
    public var updatedAt = Date()
    public init(id: UUID = UUID(), chapter: Chapter, pages: [PageResource], sourceSnapshot: Source?) { self.id = id; self.chapter = chapter; self.pages = pages; self.sourceSnapshot = sourceSnapshot }
}
public struct TransferResult: Sendable {
    public let file: URL; public let statusCode: Int; public let bytes: Int
    public init(file: URL, statusCode: Int, bytes: Int) { self.file = file; self.statusCode = statusCode; self.bytes = bytes }
}
public struct TransferRecord: Sendable {
    public let taskID: UUID; public let state: DownloadState
    public init(taskID: UUID, state: DownloadState) { self.taskID = taskID; self.state = state }
}
public protocol PageTransferring: Sendable {
    func download(_ request: ResourceRequest, sourceID: SourceID, taskID: UUID, to: URL) async throws -> TransferResult
    func recoverTransfers() async throws -> [TransferRecord]
}
