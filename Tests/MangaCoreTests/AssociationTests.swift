#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct AssociationTests {
    @Test(arguments: associationChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
