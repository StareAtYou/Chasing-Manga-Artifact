#if canImport(Testing)
import Testing
import MangaChecksSupport
@Suite struct TemplateParserTests {
    @Test(arguments: templateParserChecks) func contract(_ check: Check) async throws { try await check.body() }
}
#endif
