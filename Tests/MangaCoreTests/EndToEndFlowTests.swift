#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct EndToEndFlowTests {
    @Test(arguments: endToEndFlowChecks) func behavior(_ check: Check) async throws { try await check.body() }
}
#endif
