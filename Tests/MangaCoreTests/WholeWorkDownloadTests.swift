#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct WholeWorkDownloadTests {
    @Test(arguments: wholeWorkDownloadChecks) func contract(_ check:Check) async throws {try await check.body()}
}
#endif
