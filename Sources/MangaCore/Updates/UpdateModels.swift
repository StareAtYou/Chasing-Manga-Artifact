import Foundation
public protocol NotificationDelivering: Sendable { func notify(workID: WorkID, chapters: [Chapter]) async throws }
public struct UpdateObservation: Codable, Sendable, Identifiable {
    public var id: SourceWorkID { sourceWorkID }
    public let sourceWorkID: SourceWorkID
    public var baseline: Set<ChapterID>
    public var newChapters: [Chapter]
    public var checkedAt: Date
    public var attemptedBatches: Set<String>
    public init(sourceWorkID: SourceWorkID, baseline: Set<ChapterID>, newChapters: [Chapter] = [], checkedAt: Date = Date(), attemptedBatches: Set<String> = []) {
        self.sourceWorkID = sourceWorkID; self.baseline = baseline; self.newChapters = newChapters; self.checkedAt = checkedAt; self.attemptedBatches = attemptedBatches
    }
}
public struct UpdateResult: Sendable {
    public let sourceWorkID: SourceWorkID
    public let newChapters: [Chapter]
    public let error: MangaError?
    public let notificationError: MangaError?
    public init(sourceWorkID: SourceWorkID, newChapters: [Chapter] = [], error: MangaError? = nil, notificationError: MangaError? = nil) {
        self.sourceWorkID = sourceWorkID; self.newChapters = newChapters; self.error = error; self.notificationError = notificationError
    }
}
