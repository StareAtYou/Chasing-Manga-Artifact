import Testing
import MangaChecksSupport
@Suite struct RecommendationAppTests {
    @Test(arguments: recommendationAppChecks) func contract(_ check: Check) async throws { try await check.body() }
}
