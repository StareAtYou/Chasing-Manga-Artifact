import Foundation
import MangaCore
import MangaUI
import MangaPlatform
private actor RecommendationAppClient: HTTPClient {
    var failFirst = false
    func fail() { failFirst = true }
    func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        if failFirst && request.url.host == "first.fixture.invalid" { throw MangaError.networkUnavailable }
        return textResponse("<a href='/genre/adventure'>冒险</a><section><h2>人气排行</h2><a data-work-id='demo' href='/work/demo'>原创样本</a></section>", request.url)
    }
}
public let recommendationAppChecks: [Check] = [
    Check("RecommendationAppTests.partialFailureRetainsOtherSourcesAndLabelsCache") { @MainActor in
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let client = RecommendationAppClient()
        let app = try AppContainer(root: root, client: client, registry: ParserRegistry(adapters: [HTMLTemplateAdapter()]), transfer: FixtureTransfer(data: try generatedPNG()), notifications: FixtureNotifier())
        var ids: [SourceID] = []
        for host in ["first.fixture.invalid", "second.fixture.invalid"] {
            let source = Source(name: host, baseURL: URL(string: "https://" + host + "/")!, binding: ParserBinding(parserID: "html-declared-v1"))
            try await app.store.save(source: source); ids.append(source.id)
        }
        try await app.refresh(); await app.prepareRecommendations(force: true)
        try expect(app.currentRecommendations.count == 2 && app.recommendationGenres == ["冒险"], "Both valid sources contribute genuine genres")
        await client.fail(); await app.prepareRecommendations(force: true)
        try expect(app.currentRecommendations.map(\.sourceID) == [ids[1]] && app.cachedRecommendations.map(\.sourceID) == [ids[0]], "Failed source cache stays separate from current popular recommendations")
        await app.setEnabled(false, sourceID: ids[1])
        try expect(app.currentRecommendations.isEmpty && app.cachedRecommendations.count == 1, "Disabling a source immediately excludes its content without removing other source caches")
    }
]
