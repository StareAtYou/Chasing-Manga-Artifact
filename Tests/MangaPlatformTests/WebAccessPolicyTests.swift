#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct WebAccessPolicyTests {
    @Test(arguments: webAccessPolicyChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
