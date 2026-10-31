#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct McCMSSourceTests {
    @Test(arguments: mcCMSChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
