import Foundation
import MangaCore
import MangaPlatform
import MangaUI
func readingFixture() async throws -> (ReadingSession, LibraryStore, Chapter, URL) {
    let directory = try Samples.temporaryDirectory(); let store = try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
    var source = Samples.sourceA; source.binding = ParserBinding(parserID: "html-declared-v1"); try await store.save(source: source)
    let work = Samples.work(); let chapter = Samples.chapter(work); try await store.save(sourceWork: work, chapters: [chapter]); _ = try await store.createWork(from: work.id)
    let client = FixtureHTTPClient([chapter.url.absoluteString: textResponse("<main data-manga-reader><img data-page-id='a' src='/a.png'><img data-page-id='b' src='/b.png'></main>", chapter.url)])
    let sources = SourceService(store: store, registry: ParserRegistry(), client: client, verifier: ImageVerifier())
    return (ReadingSession(store: store, sources: sources), store, chapter, directory)
}
public let readingSessionChecks: [Check] = [
    Check("ReadingSessionTests.materializesVisibleImagesBeforeNativeOffsetCorrection") {
        let old = ReadingScrollLayout(rows: [.init(id: "a", height: 1000), .init(id: "b", height: 1000), .init(id: "c", height: 1000)])
        let prepend = ReadingScrollLayout(rows: [.init(id: "previous", height: 2000), .init(id: "a", height: 1000), .init(id: "b", height: 1000), .init(id: "c", height: 1000)])
        try expect(prepend.materializedRows(from: old, offset: 1100, viewportHeight: 400, margin: 0) == ["b"], "Visible image stays mounted in the first prepend layout pass, before the scroll callback")
        let trim = ReadingScrollLayout(rows: [.init(id: "b", height: 1000), .init(id: "c", height: 1000)])
        try expect(trim.materializedRows(from: old, offset: 2200, viewportHeight: 400, margin: 0) == ["c"], "Trimming cannot replace the retained visible image with a blank placeholder")
    },
    Check("ReadingSessionTests.scrollLayoutPreservesPixelsThroughChapterChanges") {
        let old = ReadingScrollLayout(rows: [.init(id: "top", height: 64, anchors: false), .init(id: "a", height: 900), .init(id: "b", height: 800), .init(id: "bottom", height: 64, anchors: false)])
        let prepend = ReadingScrollLayout(rows: [.init(id: "top", height: 64, anchors: false), .init(id: "previous", height: 1200), .init(id: "a", height: 900), .init(id: "b", height: 800), .init(id: "bottom", height: 64, anchors: false)])
        try expect(prepend.preservingOffset(from: old, offset: 400) == 1600, "Prepending keeps the same pixel within the current page")
        try expect(prepend.preservingOffset(from: old, offset: 0) == 1200, "A visible top boundary must not anchor to the new first chapter")
        let trim = ReadingScrollLayout(rows: [.init(id: "top", height: 64, anchors: false), .init(id: "b", height: 800), .init(id: "c", height: 600), .init(id: "bottom", height: 64, anchors: false)])
        try expect(trim.preservingOffset(from: old, offset: 1100) == 200, "Removing an older chapter subtracts its exact height without a delayed page jump")
        let append = ReadingScrollLayout(rows: [.init(id: "top", height: 64, anchors: false), .init(id: "a", height: 900), .init(id: "b", height: 800), .init(id: "c", height: 700), .init(id: "bottom", height: 64, anchors: false)])
        try expect(append.preservingOffset(from: old, offset: 1100) == 1100, "Appending cannot move existing content")
    },
    Check("ReadingSessionTests.scrollLayoutPreservesLoadedImagePoint") {
        let old = ReadingScrollLayout(rows: [.init(id: "a", height: 1000), .init(id: "b", height: 800)])
        let resized = ReadingScrollLayout(rows: [.init(id: "a", height: 2000), .init(id: "b", height: 800)])
        try expect(resized.preservingOffset(from: old, offset: 1200) == 2200, "An image above the viewport can grow without pushing the visible next page down")
        try expect(resized.preservingOffset(from: old, offset: 250) == 500, "The same relative point remains visible when the current image resolves its true aspect ratio")
        try expect(old.preservingOffset(from: old, offset: -25) == -25, "Rubber-band movement is not quantized or snapped")
    },
    Check("ReadingSessionTests.failedAdjacentLoadRetainsActiveChapter") {
        let (session, _, chapter, root) = try await readingFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try await session.open(chapter: chapter, preferences: ReaderPreferences())
        let unavailable = Chapter(id: ChapterID(sourceWorkID: chapter.id.sourceWorkID, externalID: "missing"), title: "缺失章节", url: chapter.url.appendingPathComponent("missing"), ordinal: 2)
        do { _ = try await session.prepare(chapter: unavailable); throw CheckFailure(description: "Missing chapter must fail") } catch is MangaError { }
        try expect(await session.state?.pages == original.pages, "Adjacent parse failure leaves current pages intact")
        do { _ = try await session.prepare(chapter: Samples.chapter(Samples.work(Samples.sourceB))); throw CheckFailure(description: "Cross-source chapter must not join this reader") } catch MangaError.chapterUnavailable { }
        try await session.close()
        do { _ = try await session.prepare(chapter: chapter); throw CheckFailure(description: "Closed reader must not reopen from a late callback") } catch MangaError.chapterUnavailable { }
    },
    Check("ReadingSessionTests.preparesDownloadedAdjacentChapterOffline") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root)
        let work = try await app.store.allSourceWorks()[0]; let chapters = try await app.store.chapters(for: work.id)
        for chapter in chapters {
            let pages = try await app.sources.pages(chapter: chapter)
            let id = try await app.downloads.enqueue(chapter: chapter, pages: pages)
            _ = try await waitForDownload(app.downloads, id)
        }
        try await app.store.remove(sourceID: work.id.sourceID)
        let client = FixtureHTTPClient([:])
        let sources = await SourceService(store: app.store, registry: ParserRegistry(), client: client, verifier: ImageVerifier())
        let reader = await ReadingSession(store: app.store, sources: sources, downloads: app.downloads)
        _ = try await reader.open(chapter: chapters[0], preferences: ReaderPreferences())
        let next = try await reader.prepare(chapter: chapters[1])
        try expect(next.pages.count == 4 && next.offlineFiles.count == 4, "Offline adjacent chapter retains all downloaded files")
        try expect(await client.requests.isEmpty, "Offline continuation does not contact a removed source")
        try await reader.recordPosition(pageID: next.pages.last!.id, fraction: 0.5); try await reader.close()
        await app.updateScheduler.stop()
    },
    Check("ReadingSessionTests.preparedChapterDoesNotChangeVisibleProgress") {
        let (session, store, chapter, root) = try await readingFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let second = Chapter(id: ChapterID(sourceWorkID: chapter.id.sourceWorkID, externalID: "2"), title: "第2话", url: chapter.url, ordinal: 1)
        let original = try await session.open(chapter: chapter, preferences: ReaderPreferences())
        try await session.recordPosition(pageID: original.pages[1].id, fraction: 0.4)
        let prepared = try await session.prepare(chapter: second)
        try expect(await session.state?.chapter.id == chapter.id, "Loading adjacent content must not advance title or progress")
        try await session.recordPosition(pageID: prepared.pages[0].id, fraction: 0.25)
        try expect(await session.state?.chapter.title == "第2话", "Visible page activates its chapter")
        try await session.close()
        let saved = try await store.progress(for: chapter.id.sourceWorkID)
        try expect(saved?.chapterID == second.id && saved?.fraction == 0.25, "Exit persists the visible chapter instead of the entry chapter")
    },
    Check("ReadingSessionTests.canReturnToPreviousPreparedChapter") {
        let (session, _, chapter, root) = try await readingFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try await session.open(chapter: chapter, preferences: ReaderPreferences())
        let second = Chapter(id: ChapterID(sourceWorkID: chapter.id.sourceWorkID, externalID: "2"), title: "第2话", url: chapter.url, ordinal: 1)
        let prepared = try await session.prepare(chapter: second)
        try await session.recordPosition(pageID: prepared.pages[0].id, fraction: 0)
        try await session.changeBackground(.dark)
        try await session.recordPosition(pageID: original.pages.last!.id, fraction: 0.7)
        let returned = await session.state
        try expect(returned?.chapter.id == chapter.id && returned?.preferences.background == .dark, "Upward reading returns to the previous chapter and retains reader preferences")
        try await session.close()
    },
    Check("ReadingSessionTests.readerModeSwitchRetainsPage") {
        let (session, _, chapter, directory) = try await readingFixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let state = try await session.open(chapter: chapter, preferences: ReaderPreferences()); try await session.recordPosition(pageID: state.pages[1].id, fraction: 0.3)
        try await session.changeMode(.paged)
        try expect(await session.state?.progress.pageID == state.pages[1].id, "Mode switch preserves page")
    },
    Check("ReadingSessionTests.scrollFractionRoundTrips") {
        let (session, store, chapter, directory) = try await readingFixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let state = try await session.open(chapter: chapter, preferences: ReaderPreferences()); try await session.recordPosition(pageID: state.pages[1].id, fraction: 0.625); try await session.close()
        let progress = try await store.progress(for: chapter.id.sourceWorkID)
        try expect(progress?.fraction == 0.625, "Persist page-local scroll fraction")
    },
    Check("ReadingSessionTests.failedPageKeepsPlaceholder") {
        let (session, _, chapter, directory) = try await readingFixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let state = try await session.open(chapter: chapter, preferences: ReaderPreferences()); await session.recordFailure(pageID: state.pages[0].id, error: .invalidImage)
        let failed = await session.state
        try expect(failed?.pages.count == 2 && failed?.failedPages[state.pages[0].id] == .invalidImage, "Failure retains ordinal and page ID")
    },
    Check("ReadingSessionTests.sourceSwitchDoesNotOverwriteOldProgress") {
        let (session, store, chapter, directory) = try await readingFixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let state = try await session.open(chapter: chapter, preferences: ReaderPreferences()); try await session.recordPosition(pageID: state.pages[1].id, fraction: 0.5); try await session.close()
        let other = Samples.chapter(Samples.work(Samples.sourceB))
        try await session.recordPosition(pageID: Samples.pages(other)[0].id, fraction: 0)
        try expect(try await store.progress(for: chapter.id.sourceWorkID)?.pageID == state.pages[1].id, "An unrelated callback cannot overwrite old source progress")
    }
]
public let pageLayoutChecks: [Check] = [
    Check("PageLayoutTests.shortContinuousChaptersChooseVisibleReadingPage") {
        let pages = Samples.pages(Samples.chapter(Samples.work()), count: 3).map(\.id)
        let frames = [pages[0]: ReadingPageFrame(minY: 0, height: 100), pages[1]: ReadingPageFrame(minY: 130, height: 100)]
        try expect(ContinuousPageLayout.visiblePage(pages, frames: frames, viewportHeight: 600) == pages[1], "Two short visible chapters must advance focus beyond the first page")
        let mixed = [pages[0]: ReadingPageFrame(minY: -500, height: 900), pages[1]: ReadingPageFrame(minY: 440, height: 100)]
        try expect(ContinuousPageLayout.visiblePage(Array(pages.prefix(2)), frames: mixed, viewportHeight: 600, intent: 1) == pages[1], "At the bottom, downward intent can focus a short final chapter below the midpoint")
        let top = [pages[0]: ReadingPageFrame(minY: 40, height: 100), pages[1]: ReadingPageFrame(minY: 180, height: 900)]
        try expect(ContinuousPageLayout.visiblePage(pages, frames: top, viewportHeight: 600, intent: -1) == pages[0], "At the top, upward intent can focus a short first chapter above the midpoint")
        let boundary = [pages[0]: ReadingPageFrame(minY: -100, height: 400), pages[1]: ReadingPageFrame(minY: 330, height: 400)]
        try expect(ContinuousPageLayout.visiblePage(pages, frames: boundary, viewportHeight: 600) == pages[0], "Title remains on the chapter occupying the reading line")
        try expect(ContinuousPageLayout.visiblePage(pages, frames: [:], viewportHeight: 600) == nil, "Missing layout must not invent a current chapter")
    },
    Check("PageLayoutTests.firstAndOddLastPagesStandAlone") {
        let pages = Samples.pages(Samples.chapter(Samples.work()), count: 6).map(\.id)
        let ltr = PageLayout.spreads(pageIDs: pages, direction: .leftToRight); let rtl = PageLayout.spreads(pageIDs: pages, direction: .rightToLeft)
        try expect(ltr == [[pages[0]], [pages[1], pages[2]], [pages[3], pages[4]], [pages[5]]], "Cover stands alone; unpaired last page stays alone")
        try expect(rtl == [[pages[0]], [pages[2], pages[1]], [pages[4], pages[3]], [pages[5]]], "RTL reverses visual pair only")
    }
]
