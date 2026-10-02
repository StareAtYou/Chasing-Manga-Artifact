#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct SearchServiceTests {
    @Test(arguments: searchServiceChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
