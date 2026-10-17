import Foundation
import MangaCore
import MangaPlatform
actor SearchFixtureClient: HTTPClient {
    let holdOld: Bool
    var oldStarted = false
    private var oldGate: CheckedContinuation<Void, Never>?
    init(holdOld: Bool = false) { self.holdOld = holdOld }
    func releaseOld() { oldGate?.resume(); oldGate = nil }
    func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        if sourceID == Samples.sourceB.id { try await Task.sleep(for: .milliseconds(30)); throw MangaError.timedOut }
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
        if query == "old", holdOld { oldStarted = true; await withCheckedContinuation { oldGate = $0 } }
        return textResponse("<a data-work-id='42' href='/comic/42'>\(query)</a>", request.url)
    }
}
func searchFixture(client: SearchFixtureClient = SearchFixtureClient()) async throws -> (SearchService, LibraryStore, URL) {
    let directory = try Samples.temporaryDirectory(); let store = try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
    var template = HTMLTemplate(); template.searchPath = "/search?query={query}"
    for original in [Samples.sourceA, Samples.sourceB] { var source = original; source.binding = ParserBinding(parserID: "test-search"); source.capabilities = [.search]; try await store.save(source: source) }
    let sources = SourceService(store: store, registry: ParserRegistry(adapters: [HTMLTemplateAdapter(id: "test-search", template: template)]), client: client, verifier: ImageVerifier())
    return (SearchService(store: store, sources: sources), store, directory)
}
public let searchServiceChecks: [Check] = [
    Check("SearchServiceTests.fastSourceReturnsBeforeSlowFailure") {
        let (service, _, directory) = try await searchFixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(); var events: [SearchEvent] = []
        for await event in await service.search(query: "test", sourceIDs: [Samples.sourceA.id, Samples.sourceB.id], queryID: id) { events.append(event) }
        guard case .results(let query, let source, let works) = events.first else { throw CheckFailure(description: "Fast results should precede failure") }
        try expect(query == id && source == Samples.sourceA.id && works.count == 1, "Partial search works")
        try expect(events.contains { if case .failure(_, _, .timedOut) = $0 { return true }; return false }, "Slow error remains independent")
    },
    Check("SearchServiceTests.oldQueryCannotReplaceNewResults") {
        let client = SearchFixtureClient(holdOld: true)
        let (service, _, directory) = try await searchFixture(client: client); defer { try? FileManager.default.removeItem(at: directory) }
        let oldID = UUID(); let old = await service.search(query: "old", sourceIDs: [Samples.sourceA.id], queryID: oldID)
        let oldTask = Task { var results: [SourceWork] = []; for await event in old { if case .results(_, _, let items) = event { results += items } }; return results }
        for _ in 0..<1000 { if await client.oldStarted { break }; try await Task.sleep(for: .milliseconds(1)) }
        try expect(await client.oldStarted, "Old request must be pending before it is superseded")
        let newID = UUID(); var names: [String] = []
        let new = await service.search(query: "new", sourceIDs: [Samples.sourceA.id], queryID: newID)
        await client.releaseOld()
        for await event in new { if case .results(let id, _, let items) = event { try expect(id == newID, "Tag correct query"); names += items.map(\.title) } }
        let oldResults = await oldTask.value
        try expect(names == ["new"] && oldResults.isEmpty, "Superseded query must not emit stale results")
    }
]
public let associationChecks: [Check] = [
    Check("AssociationTests.sameTitleIsNotAutomaticallyMerged") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite")); let a = Samples.work(); let b = Samples.work(Samples.sourceB)
        try await store.save(sourceWork: a, chapters: []); try await store.save(sourceWork: b, chapters: [])
        let first = try await store.createWork(from: a.id); _ = try await store.createWork(from: b.id)
        let service = AssociationService(store: store)
        try expect(service.candidates(for: a, among: [b]).count == 1, "Offer candidate")
        try expect(try await store.library().count == 2, "Do not merge before explicit confirmation")
        try await service.confirmLink(b.id, to: first.id)
        try expect(try await store.library().count == 1, "Explicit link merges association")
    },
    Check("AssociationTests.seasonAndEditionRemainDistinct") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = AssociationService(store: try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite")))
        var a = Samples.work(); var b = Samples.work(Samples.sourceB); a.title = "漫画 第1季"; b.title = "漫画 第2季"; a.aliases = ["漫画"]; b.aliases = ["漫画"]
        try expect(service.candidates(for: a, among: [b]).isEmpty, "Season difference cannot disappear through aliases")
        a.title = "漫画 彩色版"; b.title = "漫画 黑白版"
        try expect(service.candidates(for: a, among: [b]).isEmpty, "Edition remains distinct")
    }
]
public let resumeMatcherChecks: [Check] = [
    Check("ResumeMatcherTests.splitChapterRequiresSelection") {
        let a = Samples.work(); let b = Samples.work(Samples.sourceB)
        var old = Samples.chapter(a, externalID: "12"); old.title = "第12话 开始"
        var upper = Samples.chapter(b, externalID: "12-up"); upper.title = "第12话（上） 开始"
        var lower = Samples.chapter(b, externalID: "12-down"); lower.title = "第12话（下） 开始"
        let progress = ReadingProgress(chapterID: old.id, pageID: Samples.pages(old)[0].id, fraction: 0.5)
        let candidates = ResumeMatcher.candidates(progress: progress, from: [old], to: [upper, lower])
        try expect(candidates == [upper.id, lower.id] && progress.sourceWorkID == a.id, "Return both candidates; never mutate progress")
    }
]
