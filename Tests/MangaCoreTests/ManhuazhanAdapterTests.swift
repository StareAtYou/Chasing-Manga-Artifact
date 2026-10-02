#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct ManhuazhanAdapterTests {
    @Test(arguments: manhuazhanAdapterChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
