#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct MangaBZAdapterTests {
    @Test(arguments: mangaBZAdapterChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
