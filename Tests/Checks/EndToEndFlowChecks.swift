import Foundation
import MangaCore
import MangaPlatform
import MangaUI
public let endToEndFlowChecks: [Check] = [
    Check("EndToEndFlowTests.chooseSourceReadAndResume") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root)
        let source = try await app.store.sources().last!
        let events = await app.search.search(query: "原创样本", sourceIDs: [source.id], queryID: UUID())
        var results: [SourceWork] = []
        for await event in events { if case .results(_, _, let works) = event { results += works } }
        try expect(!results.isEmpty, "Search yields selected source")
        await app.select(results[0]); let group = try await app.store.workID(for: results[0].id)!
        let route = await app.navigation.selectSource(results[0].id)
        try expect(route == .chapters(results[0].id), "Manual source card selection keeps source identity")
        await app.addToShelf(group, sourceWorkID: results[0].id)
        let chapter = try await app.store.chapters(for: results[0].id)[0]
        let reader = await ReadingSession(store: app.store, sources: app.sources, downloads: app.downloads)
        let state = try await reader.open(chapter: chapter, preferences: ReaderPreferences()); try await reader.recordPosition(pageID: state.pages[2].id, fraction: 0.42); try await reader.close()
        let resumed = try await app.navigation.open(workID: group)
        try expect(resumed == .reader(chapter.id), "Shelf resumes explicitly selected source")
        let reopened = try await reader.open(chapter: chapter, preferences: ReaderPreferences()); try expect(reopened.progress.pageID == state.pages[2].id && reopened.progress.fraction == 0.42, "Page and fraction survive reopen"); try await reader.close()
    },
    Check("EndToEndFlowTests.offlineChapterAfterRestart") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root); let source = try await app.store.sources()[0]; let work = try await app.store.allSourceWorks().first { $0.id.sourceID == source.id }!; let chapter = try await app.store.chapters(for: work.id)[0]
        let pages = try await app.sources.pages(chapter: chapter); let manager = await app.downloads
        let id = try await manager.enqueue(chapter: chapter, pages: pages); _ = try await waitForDownload(manager, id)
        try await app.store.remove(sourceID: source.id)
        let db = try LibraryStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        let offlineClient = FixtureHTTPClient([:]); let sources = SourceService(store: db, registry: ParserRegistry(), client: offlineClient, verifier: ImageVerifier())
        let restarted = try DownloadManager(store: db, transfer: FixtureTransfer(data: try generatedPNG()), verifier: ImageVerifier(), root: root); try await restarted.restore()
        let session = ReadingSession(store: db, sources: sources, downloads: restarted); let state = try await session.open(chapter: chapter, preferences: ReaderPreferences())
        try expect(state.offlineFiles.count == pages.count, "Restart with removed source reads complete manifest")
        try expect(await offlineClient.requests.isEmpty, "Offline reading sends no request")
        try await session.close()
    },
    Check("EndToEndFlowTests.customSourceBindThenRead") {
        let (client, samples) = try detectionFixtures(); let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("db.sqlite")); let sources = SourceService(store: store, registry: ParserRegistry(adapters: [HTMLTemplateAdapter()]), client: client, verifier: ImageVerifier())
        let report = try await sources.add(name: "自定义", baseURL: Samples.sourceA.baseURL, samples: samples)
        try expect(report.status == .verified, "Two-work detection binds parser")
        let work = try await sources.details(url: samples[0], sourceID: report.sourceID); let chapters = try await sources.chapters(work: work); try await store.save(sourceWork: work, chapters: chapters); _ = try await store.createWork(from: work.id)
        let count = await client.requests.count; let reader = ReadingSession(store: store, sources: sources); let state = try await reader.open(chapter: chapters[0], preferences: ReaderPreferences())
        let after = await client.requests.count
        try expect(state.pages.count == 1 && after == count + 1, "Bound reader only requests its chapter, no full re-probe")
        try await reader.close()
    },
    Check("EndToEndFlowTests.updateAndDeniedNotification") {
        let (updates, _, client, _, work, root) = try await updateFixture(denied: true); defer { try? FileManager.default.removeItem(at: root) }
        _ = await updates.check(sourceWorkIDs: [work.id]); await client.setCount(3); _ = await updates.check(sourceWorkIDs: [work.id])
        let reopened = try LibraryStore(databaseURL: root.appendingPathComponent("db.sqlite")); let service = SourceService(store: reopened, registry: ParserRegistry(), client: client, verifier: ImageVerifier()); let notifier = FixtureNotifier(denied: true)
        let restarted = UpdateService(store: reopened, sources: service, notifications: notifier); _ = await restarted.check(sourceWorkIDs: [work.id])
        let observations = try await restarted.observations(); let calls = await notifier.calls
        try expect(observations.first?.newChapters.count == 1 && calls == 0, "Restart retains update and doesn't duplicate denied reminder")
    }
]
