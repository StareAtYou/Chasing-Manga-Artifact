#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct QwantzAdapterTests {
    @Test(arguments: qwantzAdapterChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
