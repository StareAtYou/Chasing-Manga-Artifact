#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct NavigationStateTests {
    @Test(arguments: navigationStateChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
