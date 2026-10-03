import Testing
import MangaChecksSupport
@Suite struct ShelfDownloadTests {
    @Test(arguments:shelfDownloadChecks) func contract(_ check:Check) async throws {try await check.body()}
}
