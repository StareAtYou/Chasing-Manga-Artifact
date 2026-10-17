#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct TransferPerformanceTests {
    @Test(arguments: transferPerformanceChecks) func contract(_ check: Check) async throws { try await check.body() }
}
@Suite struct SourceReadingTests {
    @Test(arguments: sourceReadingChecks) func contract(_ check: Check) async throws { try await check.body() }
}
@Suite struct BackgroundThroughputTests {
    @Test(arguments: backgroundThroughputChecks) func contract(_ check: Check) async throws { try await check.body() }
}
@Suite struct GuaziAccessTests {
    @Test(arguments: guaziBrowserChecks) func browserReadiness(_ check: Check) async throws { try await check.body() }
    @Test(arguments: guaziAccessChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
