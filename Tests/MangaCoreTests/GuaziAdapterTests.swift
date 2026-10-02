#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct GuaziAdapterTests {
    @Test(arguments: guaziAdapterChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
