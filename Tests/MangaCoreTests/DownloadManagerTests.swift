#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct DownloadManagerTests {
    @Test(arguments: downloadManagerChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
