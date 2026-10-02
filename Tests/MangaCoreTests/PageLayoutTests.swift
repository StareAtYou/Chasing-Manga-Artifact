#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct PageLayoutTests {
    @Test(arguments: pageLayoutChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
