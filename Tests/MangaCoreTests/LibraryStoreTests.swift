#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct LibraryStoreTests {
    @Test(arguments: libraryStoreChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
