import Foundation
import MangaCore
import MangaPlatform
#if DEBUG
@testable import MangaUI
#else
import MangaUI
#endif
public let reviewRegressionChecks: [Check] = [
    Check("ReviewRegressionTests.staleSourceCannotRestoreOldBinding") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("db.sqlite"))
        var original = Samples.sourceA; original.binding = ParserBinding(parserID: "old")
        try await store.save(source: original)
        var stale = original; stale.baseURL = URL(string: "https://b.test/")!
        try await store.save(source: stale)
        do { try await store.save(source: stale) } catch MangaError.storage { }
        let stored = try await store.source(id: original.id)
        try expect(stored?.revision == 1 && stored?.binding == nil, "Stale repeated save cannot roll back revision or binding")
    },
    Check("ReviewRegressionTests.editPreservesCurrentParserMetadata") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("db.sqlite")); try await store.save(source: Samples.sourceA)
        _ = try await store.save(binding: ParserBinding(parserID: "new"), sourceID: Samples.sourceA.id, expectedRevision: 0)
        let edited = try await store.editSource(id: Samples.sourceA.id, name: "新名称", baseURL: Samples.sourceA.baseURL, expectedRevision: 0)
        try expect(edited.binding?.parserID == "new" && edited.capabilities.contains(.readable), "Editing fields preserves current detector metadata")
    },
    Check("ReviewRegressionTests.offlineReorderMapsFilesByIdentity") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("db.sqlite")); try await store.save(source: Samples.sourceA)
        let chapter = Samples.chapter(Samples.work()); let pages = Samples.pages(chapter, count: 3)
        let first = try DownloadManager(store: store, transfer: FixtureTransfer(data: try generatedPNG(), failAfter: 2), verifier: ImageVerifier(), root: root)
        let id = try await first.enqueue(chapter: chapter, pages: pages); let interrupted = try await waitForDownload(first, id); try expect(interrupted.completedPages == 2, "Two retained pages")
        let reordered = [pages[1], pages[0], pages[2]].enumerated().map { index, page in PageResource(id: page.id, ordinal: index, request: page.request) }
        let restarted = try DownloadManager(store: store, transfer: FixtureTransfer(data: try generatedPNG()), verifier: ImageVerifier(), root: root, refresh: { _ in reordered })
        try await restarted.restore(); try await restarted.retry(taskID: id); _ = try await waitForDownload(restarted, id)
        let files = try await restarted.offlinePages(chapterID: chapter.id)
        try expect(files.map(\.lastPathComponent) == reordered.map { ContentDigest.filename($0.id) }, "Retained files follow refreshed page identities")
        let mapping = try await restarted.offlineFiles(chapterID: chapter.id)
        try expect(mapping[pages[0].id]?.lastPathComponent == ContentDigest.filename(pages[0].id), "Reader mapping is keyed by ID, not array zip")
    },
    Check("ReviewRegressionTests.foreignSamplesNeverBind") {
        let (client, samples) = try detectionFixtures()
        let report = await SourceDetector(registry: ParserRegistry(adapters: [HTMLTemplateAdapter()]), client: client, verifier: ImageVerifier()).detect(source: Samples.sourceB, samples: samples)
        try expect(report.binding == nil && report.candidates.isEmpty, "A samples cannot validate B source")
        try expect(await client.requests.isEmpty, "Reject mismatched sample scope before contacting it")
    },
    Check("ReviewRegressionTests.sourceSubpathScopeHasSegmentBoundary") {
        let base = URL(string: "https://a.test/library/")!
        try expect(SourceScope.contains(URL(string: "https://a.test/library/work/1")!, in: base), "Subpath descendant accepted")
        try expect(!SourceScope.contains(URL(string: "https://a.test/library-other/work")!, in: base), "Sibling prefix rejected")
        try expect(!SourceScope.contains(URL(string: "https://a.test/other/work")!, in: base), "Separate same-host source rejected")
    },
    Check("ReviewRegressionTests.cookiesHonorPathExpiryAndRedirect") {
        let contexts = AccessContextStore(); let base = URL(string: "https://a.test/member/reader")!; let now = Date()
        let cookie = ScopedCookie(name: "session", value: "secret", domain: "a.test", path: "/member", secure: true, expires: now.addingTimeInterval(60))
        let id = try await contexts.register(sourceID: Samples.sourceA.id, originURL: base, cookies: [cookie])
        let member = await contexts.headers(for: id, sourceID: Samples.sourceA.id, url: base, now: now)
        let publicURL = URL(string: "https://a.test/public")!
        let other = await contexts.headers(for: id, sourceID: Samples.sourceA.id, url: publicURL, now: now)
        let lookalike = await contexts.headers(for: id, sourceID: Samples.sourceA.id, url: URL(string: "https://a.test/membership")!, now: now)
        let expired = await contexts.headers(for: id, sourceID: Samples.sourceA.id, url: base, now: now.addingTimeInterval(61))
        try expect(member["Cookie"] == "session=secret" && other["Cookie"] == nil && lookalike["Cookie"] == nil && expired["Cookie"] == nil, "Cookie restrictions survive snapshot")
        var request = URLRequest(url: publicURL); request.setValue("session=secret", forHTTPHeaderField: "Cookie")
        let redirect = await contexts.redirected(request, from: base, sourceID: Samples.sourceA.id, contextID: id, now: now)
        try expect(redirect.value(forHTTPHeaderField: "Cookie") == nil, "Same-origin redirect re-evaluates path")
        let foreign = await contexts.headers(for: id, sourceID: Samples.sourceB.id, url: base, now: now)
        try expect(foreign.isEmpty, "Cookie remains source isolated")
    },
    Check("ReviewRegressionTests.keyboardMovesWholeSpread") {
        let pages = Samples.pages(Samples.chapter(Samples.work()), count: 6).map(\.id)
        try expect(PageLayout.destination(from: pages[1], pageIDs: pages, mode: .doublePage, direction: .leftToRight, visualDelta: 1) == pages[3], "One arrow advances a displayed spread")
        try expect(PageLayout.destination(from: pages[2], pageIDs: pages, mode: .doublePage, direction: .rightToLeft, visualDelta: -1) == pages[3], "RTL visual arrow advances logical next spread")
    },
    Check("ReviewRegressionTests.readableOnlySourceCanOpenWorkURL") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root); var source = try await app.store.sources()[0]; source.capabilities = .readable; try await app.store.save(source: source)
        await app.openWorkURL(source.baseURL.appendingPathComponent("work/demo"), sourceID: source.id)
        let path = await app.path
        try expect(!path.isEmpty, "A readable-only source has a direct work URL entry")
        let saved = try await app.store.allSourceWorks().first { $0.id.sourceID == source.id }!
        try expect(await app.validatedWorks.contains(where: { $0.id == saved.id }), "Validated samples remain selectable without search or browse")
    },
    Check("ReviewRegressionTests.previewsRetainRefererAndDistinctIdentity") {
        let (client, samples) = try detectionFixtures(); var template = HTMLTemplate(); template.readerImages = ".alternative img"
        let registry = ParserRegistry(adapters: [HTMLTemplateAdapter(), HTMLTemplateAdapter(id: "alternative", template: template)])
        let report = await SourceDetector(registry: registry, client: client, verifier: ImageVerifier()).detect(source: Samples.sourceA, samples: samples)
        try expect(report.status == .ambiguous, "Competing bodies require previews")
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await MainActor.run { try AppContainer(root: root, client: client, registry: registry, transfer: FixtureTransfer(data: try generatedPNG())) }
        let first = report.candidates[0]; let second = report.candidates[1]
        try expect(first.previewResources[0].request.referer != nil, "Preview preserves original request")
        let a = try await app.previewFile(report: report, candidate: first, page: first.previewResources[0])
        let b = try await app.previewFile(report: report, candidate: second, page: second.previewResources[0])
        try expect(a != b, "Alternative preview caches cannot overwrite one another")
        let request = await client.requests.last!
        try expect(request.referer != nil, "Preview pipeline sends validated request context")
    }
]
#if DEBUG
public let readerUIRegressionChecks: [Check] = [
    Check("ReviewRegressionTests.continuousReaderFailureBelongsToItsChapter") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root); let work = try await app.store.allSourceWorks()[0]
        let base = work.url.deletingLastPathComponent().deletingLastPathComponent()
        let chapters = (0..<5).map { Chapter(id: ChapterID(sourceWorkID: work.id, externalID: String($0)), title: "第\($0)话", url: base.appendingPathComponent($0 == 4 ? "broken" : "chapter/\($0)"), ordinal: $0) }
        try await app.store.save(sourceWork: work, chapters: chapters)
        let model = await ReaderModel(app: app, chapterID: chapters[1].id); await model.load()
        for _ in 0..<2 {
            await MainActor.run { model.restoring = false }; await model.loadAdjacent(1)
            let lastPage = await model.scrollChapters.last!.pages[0].id
            await model.position(lastPage, fraction: 0, mode: .scroll)
        }
        await model.loadAdjacent(1)
        try expect(await model.adjacentErrors[1] != nil, "Unreadable adjacent chapter exposes retry without erasing current pages")
        let oldFirst = await model.scrollChapters.first!.pages[0].id
        await model.position(oldFirst, fraction: 0, mode: .scroll); await model.loadAdjacent(-1)
        await MainActor.run { model.restoring = false }
        let newLast = await model.scrollChapters.last!.pages[0].id
        await model.position(newLast, fraction: 0, mode: .scroll); await model.loadAdjacent(1)
        try expect(await model.scrollChapters.last?.chapter.id == chapters[3].id, "A failure in chapter four cannot block reloading readable chapter three")
        await model.close(); await app.updateScheduler.stop()
    },
    Check("ReviewRegressionTests.continuousReaderKeepsUnreadUntilVisible") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root)
        let sourceWork = try await app.store.allSourceWorks()[0]; let chapters = try await app.store.chapters(for: sourceWork.id)
        try await app.store.saveRecord(kind: "update-observation", key: sourceWork.id.key, value: UpdateObservation(sourceWorkID: sourceWork.id, baseline: Set(chapters.map(\.id)), newChapters: chapters))
        let model = await ReaderModel(app: app, chapterID: chapters[0].id); await model.load()
        await MainActor.run { model.restoring = false }; await model.loadAdjacent(1)
        let before = try await app.updates.observations()[0]
        try expect(before.newChapters.contains { $0.id == chapters[1].id }, "Preloaded chapter remains unread")
        let page = await model.scrollChapters.last!.pages[0].id
        await model.position(page, fraction: 0, mode: .scroll); await model.close()
        let after = try await app.updates.observations()[0]
        try expect(!after.newChapters.contains { $0.id == chapters[1].id }, "Entering the next chapter marks only that visible chapter read")
        await app.updateScheduler.stop()
    },
    Check("ReviewRegressionTests.continuousReaderBoundsWindowAcrossManyChapters") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root)
        let work = try await app.store.allSourceWorks()[0]
        let chapters = (0..<7).map { Chapter(id: ChapterID(sourceWorkID: work.id, externalID: String($0)), title: "第\($0 + 1)话", url: work.url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("chapter/\($0)"), ordinal: $0) }
        try await app.store.save(sourceWork: work, chapters: chapters)
        let model = await ReaderModel(app: app, chapterID: chapters[0].id); await model.load()
        for chapter in chapters.dropFirst() {
            await MainActor.run { model.restoring = false }; await model.loadAdjacent(1)
            let loaded = await model.scrollChapters
            try expect(loaded.count <= 3 && loaded.last?.chapter.id == chapter.id, "Continuous reading keeps a bounded, ordered chapter window")
            await MainActor.run { model.restoring = false }
            await model.position(loaded.last!.pages[0].id, fraction: 0.15, mode: .scroll)
        }
        await model.close()
        try expect(try await app.store.progress(for: work.id)?.chapterID == chapters[6].id, "Evicting distant chapters cannot overwrite visible progress")
        await app.updateScheduler.stop()
    },
    Check("ReviewRegressionTests.continuousReaderAppendsWithoutNavigationOrReadMark") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root)
        let sourceWork = try await app.store.allSourceWorks()[0]; let chapters = try await app.store.chapters(for: sourceWork.id)
        let model = await ReaderModel(app: app, chapterID: chapters[0].id); await model.load()
        await MainActor.run { model.restoring = false }
        await model.loadAdjacent(1)
        try expect(await model.scrollChapters.map(\.chapter.id) == chapters.map(\.id), "Next chapter joins the same scroll content")
        let before = await model.state
        try expect(await app.path.isEmpty && before?.chapter.id == chapters[0].id, "Preloading doesn't navigate or change the current title")
        let page = await model.scrollChapters.last!.pages[1].id
        await model.position(page, fraction: 0.45, mode: .scroll)
        let active = await model.state
        try expect(await model.chapterID == chapters[1].id && active?.chapter.title == "第2话", "Menu follows visible chapter")
        await model.mode(.paged)
        let paged = await model.state
        try expect(paged?.pages[1].id == page && paged?.progress.pageID == page, "Mode switch retains the visible chapter and page")
        await model.close()
        try expect(try await app.store.progress(for: sourceWork.id)?.chapterID == chapters[1].id, "Immediate exit preserves cross-chapter progress")
        await app.updateScheduler.stop()
    },
    Check("ReviewRegressionTests.continuousReaderPrependsAndStopsAtDirectoryEdges") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root)
        let sourceWork = try await app.store.allSourceWorks()[0]; let chapters = try await app.store.chapters(for: sourceWork.id)
        let model = await ReaderModel(app: app, chapterID: chapters[1].id); await model.load()
        await MainActor.run { model.restoring = false }
        let initialPage = await model.state!.pages[0].id
        await model.loadAdjacent(-1)
        let anchor = await model.scrollRequest
        try expect(await model.scrollChapters.first?.chapter.id == chapters[0].id && anchor?.pageID == initialPage, "Prepending keeps the original visible page as the scroll anchor")
        await MainActor.run { model.restoring = false }
        let previousPage = await model.scrollChapters.first!.pages.last!.id
        await model.position(previousPage, fraction: 0.8, mode: .scroll)
        try expect(await model.chapterID == chapters[0].id, "Previous chapter last page activates previous title")
        await model.loadAdjacent(-1); await model.loadAdjacent(1)
        try expect(await model.scrollChapters.count == 2, "Directory edges do not reload or duplicate chapters")
        await model.close(); await app.updateScheduler.stop()
    },
    Check("ReviewRegressionTests.sameReaderModeKeepsPositionEnabled") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root); let work = try await app.store.allSourceWorks()[0]; let chapter = try await app.store.chapters(for: work.id)[0]
        let model = await ReaderModel(app: app, chapterID: chapter.id); await model.load()
        await MainActor.run { model.restoring = false }; await model.mode(.scroll)
        try expect(await model.restoring == false, "Choosing current mode doesn't wait for a readiness callback that won't fire")
        await model.close()
    },
    Check("ReviewRegressionTests.scrollKeyboardRequestsVisibleMovement") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root); let work = try await app.store.allSourceWorks()[0]; let chapter = try await app.store.chapters(for: work.id)[0]
        let model = await ReaderModel(app: app, chapterID: chapter.id); await model.load(); await MainActor.run { model.restoring = false }
        await model.stepPages(visualDelta: 1)
        let request = await model.scrollRequest; let pages = await model.state!.pages
        try expect(request?.pageID == pages[1].id, "Scroll arrows request an actual scroll destination")
        await model.close()
    }
]
#else
public let readerUIRegressionChecks: [Check] = []
#endif
