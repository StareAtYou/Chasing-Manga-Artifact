import Foundation
import MangaCore
extension AppContainer {
    public func associationChoices(for workID: WorkID) async throws -> [SourceWork] {
        let associated = Set(try await store.sourceWorks(for: workID).map(\.id))
        return catalog.filter { !associated.contains($0.id) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    public func chapterTitle(_ id: ChapterID) -> String { historyTitles[id] ?? downloadList.first { $0.chapter.id == id }?.chapter.title ?? "已保存的章节" }
    public func unreadCount(for workID: WorkID) -> Int { updateList.filter { workSourceIDs[workID]?.contains($0.sourceWorkID) == true }.reduce(0) { $0 + $1.newChapters.count } }
    public func resume(_ progress: ReadingProgress) async {
        await perform {
            let source = try await store.source(id: progress.sourceWorkID.sourceID)
            let offline = (try? await downloads.offlineManifest(chapterID: progress.chapterID))?.0.state == .completed
            if source.map({ $0.enabled && !$0.removed }) == true || offline { path.append(.reader(progress.chapterID)) }
            else if let workID = try await store.workID(for: progress.sourceWorkID) { path.append(.work(workID)); message = "上次阅读的来源当前不可用，请选择其他关联来源。" }
            else { throw MangaError.chapterUnavailable }
        }
    }
    public func coverFile(work: SourceWork) async throws -> URL {
        guard let url = work.coverURL else { throw MangaError.invalidURL }
        let chapter = ChapterID(sourceWorkID: work.id, externalID: "__cover__")
        let id = PageID(chapterID: chapter, externalID: ContentDigest.hex(Data(url.absoluteString.utf8)))
        let page = PageResource(id: id, ordinal: 0, request: ResourceRequest(url: url, referer: work.url))
        return try await images.file(for: page, sourceID: work.id.sourceID, priority: .prefetch)
    }
    public func chooseSource(_ sourceWorkID: SourceWorkID, for workID: WorkID) async {
        await perform {
            try await store.setPreferredSource(sourceWorkID, for: workID)
            path.append(navigation.selectSource(sourceWorkID)); try await refresh()
        }
    }
    public func linkResult(_ result: SourceWork, to workID: WorkID) async {
        await perform {
            let item = try await sources.loadWork(url: result.url, sourceID: result.id.sourceID)
            try await store.save(sourceWork: item.work, chapters: item.chapters)
            try await associations.confirmLink(item.work.id, to: workID); try await refresh()
        }
    }
    public func removeFromShelf(_ workID: WorkID) async {
        await perform {
            for source in try await store.sourceWorks(for: workID) { try await updates.setFollowed(false, sourceWorkID: source.id) }
            try await store.setOnShelf(false, workID: workID); try await refresh()
        }
    }
}
