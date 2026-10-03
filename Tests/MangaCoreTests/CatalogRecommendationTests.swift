import Testing
import MangaChecksSupport
@Suite struct CatalogRecommendationTests {
    @Test(arguments:catalogRecommendationChecks) func contract(_ check:Check) async throws {try await check.body()}
}
