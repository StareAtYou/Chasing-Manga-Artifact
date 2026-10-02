#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct DM5AdapterTests {
    @Test(arguments: dm5AdapterChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
