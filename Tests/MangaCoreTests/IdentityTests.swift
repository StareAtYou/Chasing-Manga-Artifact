#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct IdentityTests {
    @Test(arguments: identityChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
