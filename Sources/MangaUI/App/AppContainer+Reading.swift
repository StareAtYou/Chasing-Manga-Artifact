import Foundation
import MangaCore

extension AppContainer {
    public func openSource(_ sourceWorkID: SourceWorkID, for workID: WorkID) async {
        guard !openingResults.contains(sourceWorkID) else { return }
        openingResults.insert(sourceWorkID); defer { openingResults.remove(sourceWorkID) }
        await perform {
            try await store.setPreferredSource(sourceWorkID, for: workID)
            let source = try await store.source(id: sourceWorkID.sourceID)
            let online = source.map { $0.enabled && !$0.removed } ?? false
            if let progress = try await store.progress(for: sourceWorkID),
               let chapter = try await store.chapter(id: progress.chapterID),
               await canRead(chapter, online: online) {
                path.append(.reader(chapter.id)); try await refresh(); return
            }
            var chapters = try await store.chapters(for: sourceWorkID)
            if chapters.isEmpty, online, let work = try await store.sourceWork(id: sourceWorkID) {
                let loaded = try await sources.loadWork(url: work.url, sourceID: sourceWorkID.sourceID)
                try await store.save(sourceWork: loaded.work, chapters: loaded.chapters)
                chapters = try await store.chapters(for: sourceWorkID)
            }
            for chapter in chapters where await canRead(chapter, online: online) {
                path.append(.reader(chapter.id)); try await refresh(); return
            }
            throw MangaError.chapterUnavailable
        }
    }

    private func canRead(_ chapter: Chapter, online: Bool) async -> Bool {
        if online && chapter.access == .available { return true }
        return (try? await downloads.offlinePages(chapterID: chapter.id))?.isEmpty == false
    }
}
