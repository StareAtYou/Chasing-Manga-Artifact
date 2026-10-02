#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct ImagePipelineTests {
    @Test(arguments: imagePipelineChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
