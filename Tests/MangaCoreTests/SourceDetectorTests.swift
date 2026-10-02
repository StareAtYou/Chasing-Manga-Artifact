#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct SourceDetectorTests {
    @Test(arguments: sourceDetectorChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
