#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct ReviewRegressionTests {
    @Test(arguments: reviewRegressionChecks + readerUIRegressionChecks) func behavior(_ check: Check) async throws { try await check.body() }
}
#endif
