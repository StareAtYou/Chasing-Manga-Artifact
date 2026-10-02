import Foundation
import MangaCore
public let navigationStateChecks: [Check] = [
    Check("NavigationStateTests.libraryResumesSelectedSource") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite")); try await store.save(source: Samples.sourceA)
        let sourceWork = Samples.work(); let chapter = Samples.chapter(sourceWork); try await store.save(sourceWork: sourceWork, chapters: [chapter])
        let work = try await store.createWork(from: sourceWork.id); try await store.save(progress: ReadingProgress(chapterID: chapter.id, pageID: Samples.pages(chapter)[0].id))
        let route = try await NavigationState(store: store).open(workID: work.id)
        try expect(route == .reader(chapter.id), "Resume the source selected by reading progress")
    },
    Check("NavigationStateTests.unavailableSourceShowsAlternatives") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite")); try await store.save(source: Samples.sourceA); try await store.save(source: Samples.sourceB)
        let a = Samples.work(); let b = Samples.work(Samples.sourceB); let chapter = Samples.chapter(a)
        try await store.save(sourceWork: a, chapters: [chapter]); try await store.save(sourceWork: b, chapters: [Samples.chapter(b)])
        let work = try await store.createWork(from: a.id); try await store.link(b.id, to: work.id); try await store.save(progress: ReadingProgress(chapterID: chapter.id, pageID: Samples.pages(chapter)[0].id)); try await store.remove(sourceID: a.id.sourceID)
        let route = try await NavigationState(store: store).open(workID: work.id)
        try expect(route == .work(work.id), "Show alternatives without silently switching source")
    },
    Check("NavigationStateTests.browsingDoesNotSilentlyAddToShelf") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite")); let sourceWork = Samples.work(); try await store.save(sourceWork: sourceWork, chapters: [])
        let browsing = try await store.createWork(from: sourceWork.id, onShelf: false)
        try expect(try await store.library().isEmpty, "Browsing is separate from adding to shelf")
        let saved = try await store.createWork(from: sourceWork.id)
        let count = try await store.library().count
        try expect(saved.id == browsing.id && count == 1, "Explicit add preserves browsing identity")
        try await store.setOnShelf(false, workID: saved.id)
        try expect(try await store.sourceWorks(for: saved.id).count == 1, "Removing shelf entry preserves associations and history")
    },
    Check("NavigationStateTests.selectingSourceRoutesToItsChapters") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let navigation = NavigationState(store: try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite")))
        try expect(navigation.selectSource(Samples.work(Samples.sourceB).id) == .chapters(Samples.work(Samples.sourceB).id), "Keep selected source identity")
    }
]
