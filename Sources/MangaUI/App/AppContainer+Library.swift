import Foundation
import MangaCore
extension AppContainer {
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
