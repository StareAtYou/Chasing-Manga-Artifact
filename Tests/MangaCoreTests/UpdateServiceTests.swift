#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct UpdateServiceTests {
    @Test(arguments: updateServiceChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
