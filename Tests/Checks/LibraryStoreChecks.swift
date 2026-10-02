import Foundation
import MangaCore
public let libraryStoreChecks: [Check] = [
    Check("LibraryStoreTests.reopenRetainsSourceScopedProgress") {
        let dir = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        let store = try LibraryStore(databaseURL: url)
        for source in [Samples.sourceA, Samples.sourceB] {
            try await store.save(source: source)
            let work = Samples.work(source); let chapter = Samples.chapter(work)
            try await store.save(sourceWork: work, chapters: [chapter])
            try await store.save(progress: ReadingProgress(chapterID: chapter.id, pageID: Samples.pages(chapter)[0].id, fraction: source.id == Samples.sourceA.id ? 0.25 : 0.75))
        }
        let reopened = try LibraryStore(databaseURL: url)
        let a = try await reopened.progress(for: Samples.work().id)
        let b = try await reopened.progress(for: Samples.work(Samples.sourceB).id)
        try expect(a?.fraction == 0.25 && b?.fraction == 0.75, "Source scoped progress survives reopening")
    },
    Check("LibraryStoreTests.mergeAndSplitRetainRecords") {
        let dir = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LibraryStore(databaseURL: dir.appendingPathComponent("library.sqlite"))
        let a = Samples.work(); let b = Samples.work(Samples.sourceB)
        let chapter = Samples.chapter(b)
        try await store.save(sourceWork: a, chapters: [Samples.chapter(a)])
        try await store.save(sourceWork: b, chapters: [chapter])
        let book = try await store.createWork(from: a.id)
        try await store.link(b.id, to: book.id)
        try await store.save(progress: ReadingProgress(chapterID: chapter.id, pageID: Samples.pages(chapter)[1].id))
        let linked = try await store.sourceWorks(for: book.id)
        try expect(linked.count == 2, "Explicit linking shows both sources")
        try await store.unlink(b.id, from: book.id)
        let remaining = try await store.sourceWorks(for: book.id)
        let progress = try await store.progress(for: b.id)
        let library = try await store.library()
        try expect(remaining.count == 1 && progress?.pageID.externalID == "2" && library.count == 2, "Splitting preserves progress and creates separate shelf entry")
    },
    Check("LibraryStoreTests.emptyResponseDoesNotEraseChapters") {
        let dir = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LibraryStore(databaseURL: dir.appendingPathComponent("library.sqlite"))
        let work = Samples.work(); try await store.save(sourceWork: work, chapters: [Samples.chapter(work)])
        try await store.save(sourceWork: work, chapters: [])
        let chapters = try await store.chapters(for: work.id)
        try expect(chapters.count == 1, "Empty network result must not clear known chapters")
    },
    Check("LibraryStoreTests.migratesWithoutDataLoss") {
        let dir = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        let first = try LibraryStore(databaseURL: url); try await first.save(source: Samples.sourceA)
        let second = try LibraryStore(databaseURL: url); let sources = try await second.sources()
        try expect(sources.count == 1 && sources[0].name == "Source A", "Schema reopening preserves data")
    },
    Check("LibraryStoreTests.staleRevisionDoesNotBind") {
        let dir = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LibraryStore(databaseURL: dir.appendingPathComponent("library.sqlite"))
        var source = Samples.sourceA; try await store.save(source: source)
        source.baseURL = URL(string: "https://a.test/new/")!; try await store.save(source: source)
        let saved = try await store.save(binding: ParserBinding(parserID: "old"), sourceID: source.id, expectedRevision: 0)
        try expect(!saved, "Edited sources reject stale bindings")
    }
]
