#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct ResumeMatcherTests {
    @Test(arguments: resumeMatcherChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
