import Foundation
import MangaCore
import MangaPlatform
actor MutableCatalogClient: HTTPClient {
    var chapterCount = 2
    var calls = 0
    func setCount(_ count: Int) { chapterCount = count }
    func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        calls += 1
        let links = (0..<chapterCount).map { "<a data-chapter-id='\($0)' href='/chapter/\($0)'>第\($0)话</a>" }.joined()
        return textResponse("<h1 data-manga-title>漫画</h1>" + links, request.url)
    }
}
actor FixtureNotifier: NotificationDelivering {
    var calls = 0
    let denied: Bool
    init(denied: Bool = false) { self.denied = denied }
    func notify(workID: WorkID, chapters: [Chapter]) async throws { calls += 1; if denied { throw MangaError.unsupported("通知权限未授权") } }
}
func updateFixture(denied: Bool = false) async throws -> (UpdateService, LibraryStore, MutableCatalogClient, FixtureNotifier, SourceWork, URL) {
    let directory = try Samples.temporaryDirectory(); let store = try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
    var source = Samples.sourceA; source.binding = ParserBinding(parserID: "html-declared-v1"); try await store.save(source: source)
    let work = Samples.work(); try await store.save(sourceWork: work, chapters: []); _ = try await store.createWork(from: work.id)
    var settings = UserSettings(); settings.notifications = true; try await store.save(settings: settings)
    let client = MutableCatalogClient(); let notifier = FixtureNotifier(denied: denied)
    let sources = SourceService(store: store, registry: ParserRegistry(), client: client, verifier: ImageVerifier())
    let updates = UpdateService(store: store, sources: sources, notifications: notifier)
    try await updates.setFollowed(true, sourceWorkID: work.id)
    return (updates, store, client, notifier, work, directory)
}
public let updateServiceChecks: [Check] = [
    Check("UpdateServiceTests.firstCheckCreatesBaseline") {
        let (service, _, _, notifier, work, directory) = try await updateFixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let results = await service.check(sourceWorkIDs: [work.id])
        let calls = await notifier.calls
        try expect(results.first?.newChapters.isEmpty == true && calls == 0, "First check is baseline, not historical updates")
    },
    Check("UpdateServiceTests.newChaptersNotifyOnce") {
        let (service, _, client, notifier, work, directory) = try await updateFixture(); defer { try? FileManager.default.removeItem(at: directory) }
        _ = await service.check(sourceWorkIDs: [work.id]); await client.setCount(3)
        let fresh = await service.check(sourceWorkIDs: [work.id]); _ = await service.check(sourceWorkIDs: [work.id])
        let calls = await notifier.calls
        try expect(fresh.first?.newChapters.count == 1 && calls == 1, "New chapter sends one notification")
    },
    Check("UpdateServiceTests.emptyResponsePreservesBaseline") {
        let (service, store, client, _, work, directory) = try await updateFixture(); defer { try? FileManager.default.removeItem(at: directory) }
        _ = await service.check(sourceWorkIDs: [work.id]); await client.setCount(0); _ = await service.check(sourceWorkIDs: [work.id]); await client.setCount(3)
        let result = await service.check(sourceWorkIDs: [work.id])
        let count = try await store.chapters(for: work.id).count
        try expect(result.first?.newChapters.count == 1 && count == 3, "Empty directory doesn't reset baseline")
    },
    Check("UpdateServiceTests.permissionDeniedStillUpdatesList") {
        let (service, _, client, _, work, directory) = try await updateFixture(denied: true); defer { try? FileManager.default.removeItem(at: directory) }
        _ = await service.check(sourceWorkIDs: [work.id]); await client.setCount(3)
        let result = await service.check(sourceWorkIDs: [work.id]); let observations = try await service.observations()
        try expect(result.first?.newChapters.count == 1 && observations.first?.newChapters.count == 1, "Notification refusal cannot lose update list")
    },
    Check("UpdateServiceTests.unfollowedSourceIsNotChecked") {
        let (service, _, client, _, work, directory) = try await updateFixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try await service.setFollowed(false, sourceWorkID: work.id); _ = await service.check(sourceWorkIDs: [work.id])
        try expect(await client.calls == 0, "Only user-followed sources checked")
    }
]
