import Foundation
public enum Route: Codable, Hashable, Sendable { case work(WorkID), chapters(SourceWorkID), reader(ChapterID) }
public struct NavigationState: Sendable {
    private let store: LibraryStore
    private let downloads: DownloadManager?
    public init(store: LibraryStore, downloads: DownloadManager? = nil) { self.store = store; self.downloads = downloads }
    public func selectSource(_ id: SourceWorkID) -> Route { .chapters(id) }
    public func open(workID: WorkID) async throws -> Route {
        guard let work = try await store.work(id: workID) else { throw MangaError.storage("作品不存在") }
        guard let preferred = work.preferredSourceWorkID, try await store.sourceWorks(for: workID).contains(where: { $0.id == preferred }), let progress = try await store.progress(for: preferred), try await store.chapter(id: progress.chapterID) != nil else { return .work(workID) }
        let source = try await store.source(id: preferred.sourceID)
        let online = source.map { $0.enabled && !$0.removed } ?? false
        let offline = (try? await downloads?.offlinePages(chapterID: progress.chapterID))?.isEmpty == false
        return online || offline ? .reader(progress.chapterID) : .work(workID)
    }
}
