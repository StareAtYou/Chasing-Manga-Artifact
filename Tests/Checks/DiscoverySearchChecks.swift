import Foundation
import MangaCore
import MangaUI
import MangaPlatform

private actor DiscoverySearchClient: HTTPClient {
    var requestedSources: [SourceID] = []
    var holdFirst = false
    var firstStarted = false
    var gate: CheckedContinuation<Void, Never>?
    func hold() { holdFirst = true }
    func release() { gate?.resume(); gate = nil }
    func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        requestedSources.append(sourceID)
        if holdFirst && sourceID == Samples.sourceA.id {
            holdFirst = false; firstStarted = true
            await withCheckedContinuation { gate = $0 }
        }
        let path = request.url.host == "www.duokanmh.com" ? "/manhua/Example" : "/comic/example"
        return textResponse("<a data-work-id='example' href='\(path)'>搜索样本</a>", request.url)
    }
}
@MainActor private func discoveryFixture(_ root: URL, client: DiscoverySearchClient) async throws -> AppContainer {
    var template = HTMLTemplate(); template.searchPath = "/search?q={query}"
    let app = try AppContainer(root: root, client: client, registry: ParserRegistry(adapters: [HTMLTemplateAdapter(id: "scoped-search", template: template)]), transfer: FixtureTransfer(data: try generatedPNG()))
    for original in [Samples.sourceA, Samples.sourceB] {
        var source = original; source.binding = ParserBinding(parserID: "scoped-search"); source.capabilities = [.search]
        try await app.store.save(source: source)
    }
    try await app.refresh()
    return app
}
@MainActor private func finishSearch(_ app: AppContainer) async throws {
    for _ in 0..<1000 {
        if !app.searching { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CheckFailure(description: "Discovery search did not complete")
}
public let discoverySearchChecks: [Check] = [
    Check("DiscoverySearchTests.defaultsToAllAndCanSelectOneSource") { @MainActor in
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DiscoverySearchClient(); let app = try await discoveryFixture(root, client: client); defer { app.cancelSearch() }
        app.searchDiscovery("样本"); try await finishSearch(app)
        try expect(Set(app.searchResults.map { $0.id.sourceID }) == [Samples.sourceA.id, Samples.sourceB.id], "Default discovery search includes both enabled sources")
        app.discoverySearchScope = .source(Samples.sourceB.id); app.searchDiscovery("样本"); try await finishSearch(app)
        try expect(app.searchResults.count == 1 && app.searchResults[0].id.sourceID == Samples.sourceB.id && app.searchErrors.isEmpty, "Selected source replaces all-source results")
        let calls = await client.requestedSources
        try expect(calls.count == 3 && calls.last == Samples.sourceB.id, "Single-source query must not contact another source")
        app.discoverySearchScope = .all; app.searchDiscovery("样本"); try await finishSearch(app)
        try expect(Set(app.searchResults.map { $0.id.sourceID }) == [Samples.sourceA.id, Samples.sourceB.id], "Switching back to all restores cross-source results")
    },
    Check("DiscoverySearchTests.scopeChangeRejectsLateResultsForSameKeyword") { @MainActor in
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DiscoverySearchClient(); let app = try await discoveryFixture(root, client: client); defer { app.cancelSearch() }
        await client.hold(); app.discoverySearchScope = .source(Samples.sourceA.id); app.searchDiscovery("相同关键词")
        for _ in 0..<1000 { if await client.firstStarted { break }; try await Task.sleep(for: .milliseconds(2)) }
        try expect(await client.firstStarted, "First scope is in flight before switching")
        app.discoverySearchScope = .source(Samples.sourceB.id); app.searchDiscovery("相同关键词")
        await client.release(); try await finishSearch(app)
        try expect(app.searchResults.count == 1 && app.searchResults[0].id.sourceID == Samples.sourceB.id, "Old scope cannot append results after the scope switches")
    },
    Check("DiscoverySearchTests.disabledSelectionNeverBroadensSearch") { @MainActor in
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DiscoverySearchClient(); let app = try await discoveryFixture(root, client: client); defer { app.cancelSearch() }
        app.discoverySearchScope = .source(Samples.sourceA.id)
        await app.setEnabled(false, sourceID: Samples.sourceA.id); app.searchDiscovery("样本"); try await finishSearch(app)
        try expect(app.searchResults.isEmpty && !app.searching, "Unavailable selection yields no results")
        try expect(await client.requestedSources.isEmpty, "Disabled single selection must not silently search other sources")
        app.discoverySearchScope = .all; app.searchDiscovery("样本"); try await finishSearch(app)
        try expect(app.searchResults.count == 1 && app.searchResults[0].id.sourceID == Samples.sourceB.id, "All-source search skips disabled source")
    },
    Check("DiscoverySearchTests.customSubsetAndEmptyScopeRemainExplicit") { @MainActor in
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DiscoverySearchClient(); let app = try await discoveryFixture(root, client: client); defer { app.cancelSearch() }
        app.discoverySearchScope = .excluding([Samples.sourceA.id]); app.searchDiscovery("样本"); try await finishSearch(app)
        try expect(app.searchResults.count == 1 && app.searchResults[0].id.sourceID == Samples.sourceB.id, "Existing custom subset remains supported")
        app.discoverySearchScope = .excluding([Samples.sourceA.id, Samples.sourceB.id]); app.searchDiscovery("样本")
        try expect(!app.searching && app.searchResults.isEmpty && app.searchErrors.isEmpty, "No selected sources clears state immediately")
        try expect(await client.requestedSources.count == 1, "Empty scope sends no additional query")
    },
    Check("DiscoverySearchTests.unprobedBuiltinsCanSearchAndUnboundCustomSourcesAreExcluded") { @MainActor in
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = DiscoverySearchClient(); let app = try await discoveryFixture(root, client: client); defer { app.cancelSearch() }
        let duokan = BuiltinSources.candidates().first { $0.baseURL.host == "www.duokanmh.com" }!
        let custom = Source(name: "未绑定来源", baseURL: URL(string: "https://unbound.fixture.invalid/")!)
        try await app.store.save(source: duokan); try await app.store.save(source: custom); try await app.refresh()
        app.discoverySearchScope = .source(duokan.id); app.searchDiscovery("样本"); try await finishSearch(app)
        try expect(app.searchResults.count == 1 && app.searchResults[0].id.sourceID == duokan.id, "Built-in search does not depend on successful startup probing")
        try expect(!app.discoverySearchSources.contains { $0.id == custom.id }, "Unbound sources without search support are not offered")
    }
]
