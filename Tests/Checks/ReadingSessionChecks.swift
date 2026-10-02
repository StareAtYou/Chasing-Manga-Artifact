import Foundation
import MangaCore
import MangaPlatform
func readingFixture() async throws -> (ReadingSession, LibraryStore, Chapter, URL) {
    let directory = try Samples.temporaryDirectory(); let store = try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
    var source = Samples.sourceA; source.binding = ParserBinding(parserID: "html-declared-v1"); try await store.save(source: source)
    let work = Samples.work(); let chapter = Samples.chapter(work); try await store.save(sourceWork: work, chapters: [chapter]); _ = try await store.createWork(from: work.id)
    let client = FixtureHTTPClient([chapter.url.absoluteString: textResponse("<main data-manga-reader><img data-page-id='a' src='/a.png'><img data-page-id='b' src='/b.png'></main>", chapter.url)])
    let sources = SourceService(store: store, registry: ParserRegistry(), client: client, verifier: ImageVerifier())
    return (ReadingSession(store: store, sources: sources), store, chapter, directory)
}
public let readingSessionChecks: [Check] = [
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
    Check("PageLayoutTests.firstAndOddLastPagesStandAlone") {
        let pages = Samples.pages(Samples.chapter(Samples.work()), count: 6).map(\.id)
        let ltr = PageLayout.spreads(pageIDs: pages, direction: .leftToRight); let rtl = PageLayout.spreads(pageIDs: pages, direction: .rightToLeft)
        try expect(ltr == [[pages[0]], [pages[1], pages[2]], [pages[3], pages[4]], [pages[5]]], "Cover stands alone; unpaired last page stays alone")
        try expect(rtl == [[pages[0]], [pages[2], pages[1]], [pages[4], pages[3]], [pages[5]]], "RTL reverses visual pair only")
    }
]
