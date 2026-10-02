#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct ImageVerifierTests {
    @Test(arguments: imageVerifierChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
