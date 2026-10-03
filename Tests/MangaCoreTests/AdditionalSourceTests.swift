#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct AdditionalSourceTests {
    @Test(arguments: additionalSourceChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
