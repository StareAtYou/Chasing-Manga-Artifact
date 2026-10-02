#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct UsabilityTests {
    @Test(arguments: usabilityChecks + usabilityReaderChecks) func behavior(_ check: Check) async throws { try await check.body() }
}
#endif
