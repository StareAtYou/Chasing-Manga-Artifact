import Foundation
import MangaCore
import MangaPlatform
#if DEBUG
@testable import MangaUI
#else
import MangaUI
#endif

actor StartupCatalogClient: HTTPClient {
    func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        let html: String
        switch request.url.host {
        case "www.guazimanhua.com": html = "<a href='/comic.php?id=7'><h2>启动作品</h2></a>"
        case "www.dm5.com": html = "<a title='启动作品' href='/manhua-demo/'>启动作品</a>"
        default: html = request.method == .post ? "<title>安全验证</title>" : "<a href='/comic/7' title='启动作品'>启动作品</a>"
        }
        return textResponse(html, request.url)
    }
}
actor LongDM5Client: HTTPClient {
    var count = 0
    let image: Data
    init() throws { image = try generatedPNG() }
    func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        count += 1
        if request.url.host == "images.test" { return ResourceResponse(data: image, finalURL: request.url, statusCode: 200) }
        if request.url.lastPathComponent == "chapterfun.ashx" {
            let page = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value ?? "1"
            return textResponse("function dm5imagefun(){var pix='https://images.test/';var pvalue=['p\(page).jpg'];pvalue[i]=pix+pvalue[i]+'?sign=current';return pvalue}var d;d=dm5imagefun();", request.url)
        }
        if request.url.path.hasPrefix("/m") && !request.url.path.hasPrefix("/manhua") {
            return textResponse(try fixtureText("dm5-reader").replacingOccurrences(of: "DM5_IMAGE_COUNT=2", with: "DM5_IMAGE_COUNT=80"), request.url)
        }
        return textResponse(try fixtureText("dm5-detail"), request.url)
    }
}
actor WorkPageClient: HTTPClient {
    var count = 0
    func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        count += 1
        return textResponse("<h1 data-manga-title data-work-id='42'>测试漫画</h1><img data-manga-cover src='/cover.jpg'><div data-manga-author>作者甲</div><div data-manga-summary>内容简介</div><a data-chapter-id='1' href='/chapter/1'>第1话</a>", request.url)
    }
}
actor CoverContextClient: HTTPClient {
    let image: Data
    init() throws { image = try generatedPNG() }
    func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        guard request.referer == Samples.work().url, sourceID == Samples.sourceA.id else { throw MangaError.accessRestricted(403) }
        return ResourceResponse(data: image, finalURL: request.url, statusCode: 200)
    }
}
actor RefreshCounter {
    var count = 0
    func refreshed(_ pages: [PageResource]) -> [PageResource] { count += 1; return pages }
}
actor PriorityCaptureClient: HTTPClient {
    var observed: [RequestPriority] = []
    func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse { observed.append(priority); return textResponse("<div data-manga-reader><img data-page-id='1' src='https://images.test/1.png'></div>", request.url) }
}
public let usabilityChecks: [Check] = [
    Check("UsabilityTests.downloadPreparationYieldsToReading") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("db.sqlite")); var source = Samples.sourceA; source.binding = ParserBinding(parserID: "html-declared-v1"); try await store.save(source: source)
        let client = PriorityCaptureClient(); let service = SourceService(store: store, registry: ParserRegistry(), client: client, verifier: ImageVerifier())
        _ = try await service.pages(chapter: Samples.chapter(Samples.work()), priority: .download)
        try expect(await client.observed.allSatisfy { $0 == .download }, "Adapter reader defaults must not promote background preparation ahead of reading")
    },
    Check("UsabilityTests.siteListingsExcludeNavigationAndCoverSuffix") {
        let dm = BuiltinSources.candidates()[2]
        let html = "<nav><a href='/manhua-new/'>更新</a><a href='/manhua-rank/'>排行</a><a href='/manhua-riman/'>日漫</a></nav><div class='mh-item'><p class='mh-cover' style='background-image: url(https://covers.test/c.jpg)'></p><h2><a title='真实漫画' href='/manhua-demo/'>真实漫画</a></h2></div>"
        let works = try await DM5Adapter().browse(context: ParserContext(source: dm, client: FixtureHTTPClient([dm.baseURL.absoluteString: textResponse(html, dm.baseURL)])))
        try expect(works.map(\.title) == ["真实漫画"] && works.first?.coverURL?.host == "covers.test", "Navigation is not a comic, CSS cover belongs to its containing card")
        let guazi = BuiltinSources.candidates()[1]
        let page = "<a href='/comic.php?id=7'><img alt='漫画甲漫画封面' src='/cover.jpg'></a><a href='/comic.php?id=7'><h2>漫画甲</h2></a>"
        let found = try await GuaziAdapter().browse(context: ParserContext(source: guazi, client: FixtureHTTPClient([guazi.baseURL.absoluteString: textResponse(page, guazi.baseURL)])))
        try expect(found.first?.title == "漫画甲", "Cover accessibility suffix does not become the comic title")
    },
    Check("UsabilityTests.browsingRetainsRealSiteCovers") {
        for (adapter, source, html) in [
            (ManhuazhanAdapter() as any SourceAdapter, BuiltinSources.candidates()[0], "<a href='/comic/7' title='漫画'><img data-original='/cover.jpg'></a>"),
            (DM5Adapter() as any SourceAdapter, BuiltinSources.candidates()[2], "<a href='/manhua-demo/' title='漫画'><img src='/cover.jpg'></a>")
        ] {
            let found = try await adapter.browse(context: ParserContext(source: source, client: FixtureHTTPClient([source.baseURL.absoluteString: textResponse(html, source.baseURL)])))
            try expect(found.first?.coverURL?.path == "/cover.jpg", "\(source.name) discovery keeps the actual cover image")
        }
    },
    Check("UsabilityTests.batchDownloadsPersistDistinctChapters") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root); let work = try await app.store.allSourceWorks()[0]; let chapters = try await app.store.chapters(for: work.id)
        await app.queueDownloads(chapters)
        let tasks = try await app.downloads.tasks()
        try expect(Set(tasks.map { $0.chapter.id }) == Set(chapters.map(\.id)), "Selected chapters create distinct durable tasks")
        for task in tasks { _ = try await waitForDownload(app.downloads, task.id) }
        await app.queueDownloads(chapters)
        try expect(try await app.downloads.tasks().count == chapters.count, "Repeated selection does not duplicate completed downloads")
        await app.updateScheduler.stop()
    },
    Check("UsabilityTests.updateFailureSurvivesRelaunch") {
        let (service, store, client, notifier, work, root) = try await updateFixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = await service.check(sourceWorkIDs: [work.id]); await client.setCount(0); _ = await service.check(sourceWorkIDs: [work.id])
        let restarted = UpdateService(store: store, sources: SourceService(store: store, registry: ParserRegistry(), client: client, verifier: ImageVerifier()), notifications: notifier)
        let statuses = try await restarted.checkStatuses()
        try expect(statuses.first?.error != nil, "Failure remains visible after reopening updates")
        await client.setCount(3); _ = await restarted.check(sourceWorkIDs: [work.id])
        try expect(try await restarted.checkStatuses().first?.error == nil, "Successful retry clears stale error")
    },
    Check("UsabilityTests.emptyUpdateReportsFailure") {
        let (service, _, client, _, work, root) = try await updateFixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = await service.check(sourceWorkIDs: [work.id]); await client.setCount(0)
        let result = await service.check(sourceWorkIDs: [work.id])
        try expect(result.first?.error != nil, "Empty directory must report failure instead of no updates")
    },
    Check("UsabilityTests.enqueueRetriesFailedChapter") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("db.sqlite")); try await store.save(source: Samples.sourceA)
        let chapter = Samples.chapter(Samples.work()); let pages = Samples.pages(chapter)
        let failing = try DownloadManager(store: store, transfer: FixtureTransfer(data: try generatedPNG(), failAfter: 0), verifier: ImageVerifier(), root: root)
        let id = try await failing.enqueue(chapter: chapter, pages: pages); _ = try await waitForDownload(failing, id)
        let retry = try DownloadManager(store: store, transfer: FixtureTransfer(data: try generatedPNG()), verifier: ImageVerifier(), root: root)
        let queued = try await retry.enqueue(chapter: chapter, pages: pages); let done = try await waitForDownload(retry, queued)
        try expect(queued == id && done.state == .completed, "Download button retries failed existing task without duplicating it")
    },
    Check("UsabilityTests.coverRequestsKeepSourceReferer") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = try CoverContextClient()
        let app = try await MainActor.run { try AppContainer(root: root, client: client, transfer: FixtureTransfer(data: try generatedPNG())) }
        var work = Samples.work(); work.coverURL = URL(string: "https://covers.test/cover.jpg")!
        let file = try await app.coverFile(work: work)
        try expect((try ImageVerifier().verify(Data(contentsOf: file))).width == 16, "Real cover request must carry its work page Referer")
    },
    Check("UsabilityTests.cancelledImageConsumerKeepsOtherReaderAlive") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = ImageBlockingTransport(data: try generatedPNG()); let page = Samples.pages(Samples.chapter(Samples.work()))[0]
        let pipeline = ImagePipeline(client: URLSessionHTTPClient(transport: transport), files: try PageFileStore(root: root))
        let first = Task { try await pipeline.file(for: page, sourceID: Samples.sourceA.id) }
        while await transport.paths.isEmpty { await Task.yield() }
        let second = Task { try await pipeline.file(for: page, sourceID: Samples.sourceA.id) }
        for _ in 0..<500 { await Task.yield() }
        first.cancel(); await transport.release(); _ = try? await first.value
        let retained = try await second.value
        try expect(FileManager.default.fileExists(atPath: retained.path), "One disappearing view must not cancel another view waiting for the same image")
    },
    Check("UsabilityTests.manualAssociationPreservesBothSourceProgresses") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root); let sources = try await app.store.allSourceWorks(); let first = sources[0]; let second = sources[1]
        let group = try await app.store.workID(for: first.id)!
        for source in sources { let chapter = try await app.store.chapters(for: source.id)[0]; try await app.store.save(progress: ReadingProgress(chapterID: chapter.id, pageID: PageID(chapterID: chapter.id, externalID: "1"), fraction: 0.25)) }
        await app.linkResult(second, to: group)
        let linked = try await app.store.sourceWorks(for: group)
        let a = try await app.store.progress(for: first.id); let b = try await app.store.progress(for: second.id)
        try expect(linked.count == 2 && a?.fraction == 0.25 && b?.fraction == 0.25, "User-confirmed result links both sources without replacing either progress")
        await app.updateScheduler.stop()
    },
    Check("UsabilityTests.chosenSourceIsFollowedWhenAddedToShelf") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root); let sources = try await app.store.allSourceWorks(); let group = try await app.store.workID(for: sources[0].id)!
        try await app.store.link(sources[1].id, to: group); try await app.store.setOnShelf(false, workID: group)
        await app.chooseSource(sources[1].id, for: group); await app.addToShelf(group, sourceWorkID: sources[1].id)
        let selected = try await app.store.work(id: group)?.preferredSourceWorkID
        try expect(selected == sources[1].id, "Source choice persists before reading starts")
        try expect(try await app.updates.isFollowed(sources[1].id), "Shelf follows the source the user selected")
        await app.updateScheduler.stop()
    },
    Check("UsabilityTests.removingShelfStopsItsUpdateSubscriptions") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root); let source = try await app.store.allSourceWorks()[0]; let group = try await app.store.workID(for: source.id)!
        await app.addToShelf(group, sourceWorkID: source.id); await app.removeFromShelf(group)
        let followed = try await app.updates.isFollowed(source.id); let progress = try await app.store.sourceWorks(for: group)
        try expect(!followed && progress.count == 1, "Shelf removal stops updates while retaining source association and history")
        await app.updateScheduler.stop()
    },
    Check("UsabilityTests.readingNewChapterClearsOnlyThatUpdate") {
        let (service, _, client, _, work, root) = try await updateFixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = await service.check(sourceWorkIDs: [work.id]); await client.setCount(4); _ = await service.check(sourceWorkIDs: [work.id])
        let new = try await service.observations()[0].newChapters
        try expect(new.count == 2, "Two updates before reading")
        try await service.markRead(chapterID: new[0].id); _ = await service.check(sourceWorkIDs: [work.id])
        let remaining = try await service.observations()[0].newChapters
        try expect(remaining.map(\.id) == [new[1].id], "Read badge clears without resetting baseline or rediscovering old updates")
    },
    Check("UsabilityTests.siteMetadataSelectors") {
        let guazi = BuiltinSources.candidates()[1]; let guaziURL = guazi.baseURL.appendingPathComponent("comic.php?id=7")
        let g = "<h1 id='cinema-title'>作品甲</h1><img class='cinema-cover' src='/cover.jpg'><div class='cinema-strip'><a href='/author.php?name=a'>作者甲</a></div><p class='mobile-comic-desc'>简介甲</p>"
        let work = try await GuaziAdapter().details(url: guaziURL, context: ParserContext(source: guazi, client: FixtureHTTPClient([guaziURL.absoluteString: textResponse(g, guaziURL)])))
        try expect(work.author == "作者甲" && work.coverURL != nil && work.summary == "简介甲", "Guazi real page shape retains metadata")
        let manhua = BuiltinSources.candidates()[0]; let url = manhua.baseURL.appendingPathComponent("comic/7")
        let m = "<h1>作品乙</h1><div class='d-vod-pic'><img src='/cover.jpg'></div><div class='d-vod-type'><p><span>作者：</span>作者乙</p></div><div class='d-des'>简介乙</div>"
        let other = try await ManhuazhanAdapter().details(url: url, context: ParserContext(source: manhua, client: FixtureHTTPClient([url.absoluteString: textResponse(m, url)])))
        try expect(other.author == "作者乙" && other.summary == "简介乙", "Manhuazhan real page shape retains metadata")
    },
    Check("UsabilityTests.openWorkLinkFetchesDocumentOnce") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = WorkPageClient()
        let app = try await MainActor.run { try AppContainer(root: root, client: client, transfer: FixtureTransfer(data: try generatedPNG())) }
        var source = Samples.sourceA; source.binding = ParserBinding(parserID: "html-declared-v1"); try await app.store.save(source: source)
        await app.openWorkURL(Samples.work().url, sourceID: source.id)
        try expect(await app.path.count == 1, "Direct link opens one work")
        try expect(await client.count == 1, "Detail and directory extraction reuse the same document within one opening")
    },
    Check("UsabilityTests.detailRetainsCoverAuthorAndSummary") {
        let work = try await HTMLTemplateAdapter().details(url: Samples.work().url, context: ParserContext(source: Samples.sourceA, client: WorkPageClient()))
        try expect(work.coverURL?.absoluteString == "https://a.test/cover.jpg" && work.author == "作者甲" && work.summary == "内容简介", "A saved work must retain actual declared metadata instead of becoming a generic empty-cover card")
    },
    Check("UsabilityTests.narrowLongImageRetainsNativeWidth") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("long.png"); try generatedPNG(width: 100, height: 20_000).write(to: file)
        let tiles = try TiledImageDecoder().decode(file: file, viewport: PixelRect(x: 0, y: 0, width: 100, height: 20_000), targetWidth: 100)
        try expect(tiles.allSatisfy { $0.image.width == 100 }, "A long page that fits the pixel budget must not shrink to 20 pixels wide")
    },
    Check("UsabilityTests.freshDownloadUsesAlreadyResolvedPages") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("db.sqlite")); try await store.save(source: Samples.sourceA)
        let chapter = Samples.chapter(Samples.work()); let pages = Samples.pages(chapter); let counter = RefreshCounter()
        let manager = try DownloadManager(store: store, transfer: FixtureTransfer(data: try generatedPNG()), verifier: ImageVerifier(), root: root, refresh: { _ in await counter.refreshed(pages) })
        let id = try await manager.enqueue(chapter: chapter, pages: pages); let task = try await waitForDownload(manager, id)
        try expect(task.state == .completed, "Fresh download completes")
        try expect(await counter.count == 0, "Fresh chapter does not resolve every signed page twice")
    },
    Check("UsabilityTests.freshLaunchEnablesVerifiedBuiltinSearch") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await MainActor.run { try AppContainer(root: root, client: StartupCatalogClient(), transfer: FixtureTransfer(data: try generatedPNG())) }
        await app.start()
        let sources = try await app.store.sources()
        try expect(sources.first { $0.name == "瓜子漫画" }?.capabilities.contains(.search) == true, "Fresh launch probes real catalog responses instead of leaving search disabled")
        try expect(sources.first { $0.name == "漫画站" }?.capabilities.contains(.search) == false, "Challenge does not become searchable")
        await app.updateScheduler.stop()
    },
    Check("UsabilityTests.longDM5CanBindWithinProbeBudget") {
        let client = try LongDM5Client(); let source = BuiltinSources.candidates()[2]
        let report = await SourceDetector(registry: ParserRegistry(adapters: [DM5Adapter()]), client: client, verifier: ImageVerifier()).detect(source: source, samples: [source.baseURL.appendingPathComponent("manhua-demo/")])
        try expect(report.binding?.parserID == "dm5-reader" && report.candidates.first?.previewResources.count == 4, "Long chapters must sample first and last real pages without exhausting the probe budget")
        try expect(await client.count <= 30, "Probe remains bounded")
    }
]
#if DEBUG
public let usabilityReaderChecks: [Check] = [
    Check("UsabilityTests.immediateExitRetainsLastPage") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root)
        let sourceWork = try await app.store.allSourceWorks()[0]; let chapter = try await app.store.chapters(for: sourceWork.id)[0]
        let saved = await Task { @MainActor in
            let model = ReaderModel(app: app, chapterID: chapter.id); await model.load(); model.restoring = false
            let next = model.state!.pages[1].id
            model.position(next, fraction: 0.35, mode: .scroll)
            await model.close()
            return try? await app.store.progress(for: sourceWork.id)
        }.value
        try expect(saved?.pageID.externalID == "1" && saved?.fraction == 0.35, "Last visible position must flush even if user exits before the asynchronous record runs")
        await app.updateScheduler.stop()
    }
]
#else
public let usabilityReaderChecks: [Check] = []
#endif
