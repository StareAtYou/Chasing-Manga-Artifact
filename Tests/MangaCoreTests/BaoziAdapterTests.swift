#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct BaoziAdapterTests {
    @Test(arguments: baoziAdapterChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
