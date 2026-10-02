import Foundation
public actor UpdateService {
    private let store: LibraryStore
    private let sources: SourceService
    private let notifications: any NotificationDelivering
    private var checking = Set<SourceWorkID>()
    public init(store: LibraryStore, sources: SourceService, notifications: any NotificationDelivering) { self.store = store; self.sources = sources; self.notifications = notifications }
    public func setFollowed(_ followed: Bool, sourceWorkID: SourceWorkID) async throws { try await store.saveRecord(kind: "followed-source", key: sourceWorkID.key, value: FollowedSource(sourceWorkID: sourceWorkID, followed: followed)) }
    public func isFollowed(_ sourceWorkID: SourceWorkID) async throws -> Bool { try await store.record(kind: "followed-source", key: sourceWorkID.key, as: FollowedSource.self)?.followed ?? false }
    public func followedIDs() async throws -> [SourceWorkID] { try await store.records(kind: "followed-source", as: FollowedSource.self).filter(\.followed).map(\.sourceWorkID) }
    public func observations() async throws -> [UpdateObservation] { try await store.records(kind: "update-observation", as: UpdateObservation.self).sorted { $0.checkedAt > $1.checkedAt } }
    public func check(sourceWorkIDs: [SourceWorkID]) async -> [UpdateResult] {
        var results: [UpdateResult] = []
        for id in Set(sourceWorkIDs).sorted(by: { $0.key < $1.key }) {
            guard !Task.isCancelled, !checking.contains(id), (try? await isFollowed(id)) == true else { continue }
            checking.insert(id)
            do {
                guard var work = try await store.sourceWork(id: id) else { throw MangaError.storage("作品资料不存在") }
                let chapters = try await sources.chapters(work: work)
                try Task.checkCancellation()
                guard try await isFollowed(id) else { checking.remove(id); continue }
                guard !chapters.isEmpty else { results.append(UpdateResult(sourceWorkID: id)); checking.remove(id); continue }
                let before = try await store.record(kind: "update-observation", key: id.key, as: UpdateObservation.self)
                var observation = before ?? UpdateObservation(sourceWorkID: id, baseline: Set(chapters.map(\.id)))
                let new = before == nil ? [] : chapters.filter { !observation.baseline.contains($0.id) }
                observation.baseline.formUnion(chapters.map(\.id)); observation.checkedAt = Date()
                let known = Set(observation.newChapters.map(\.id)); observation.newChapters += new.filter { !known.contains($0.id) }
                work.checkedAt = Date(); work.latestChapter = chapters.last?.title ?? work.latestChapter
                var notificationError: MangaError?
                let batch = ContentDigest.hex(Data(new.map { $0.id.key }.sorted().joined(separator: "|").utf8))
                let settings = try await store.settings()
                let notify = settings.notifications && !new.isEmpty && !observation.attemptedBatches.contains(batch)
                // Persist the update and attempt marker before delivering. A process interruption
                // may lose a reminder, but cannot duplicate it or lose the update list.
                if notify { observation.attemptedBatches.insert(batch) }
                try await store.save(sourceWork: work, chapters: chapters)
                try await store.saveRecord(kind: "update-observation", key: id.key, value: observation)
                if notify, let workID = try await store.workID(for: id) {
                    do { try await notifications.notify(workID: workID, chapters: new) }
                    catch { notificationError = (error as? MangaError) ?? .unsupported("通知未发送") }
                }
                results.append(UpdateResult(sourceWorkID: id, newChapters: new, notificationError: notificationError))
            } catch is CancellationError { checking.remove(id); break }
            catch { results.append(UpdateResult(sourceWorkID: id, error: (error as? MangaError) ?? .networkUnavailable)) }
            checking.remove(id)
        }
        return results
    }
    private struct FollowedSource: Codable { let sourceWorkID: SourceWorkID; let followed: Bool }
}
