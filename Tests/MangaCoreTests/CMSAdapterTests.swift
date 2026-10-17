#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct CMSSourceTests {
    @Test(arguments: cmsAdapterChecks) func contract(_ check: Check) async throws { try await check.body() }
    @Test(arguments: cmsImageChecks) func imageContract(_ check: Check) async throws { try await check.body() }
}
#endif
