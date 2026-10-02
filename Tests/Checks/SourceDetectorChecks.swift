import Foundation
import MangaCore
import MangaPlatform

func detectionFixtures(works: Int = 2) throws -> (FixtureHTTPClient, [URL]) {
    var responses: [String: ResourceResponse] = [:]; var samples: [URL] = []
    let png = try generatedPNG()
    for w in 1...works {
        let url = URL(string: "https://a.test/work/\(w)")!; samples.append(url)
        let html = "<h1 data-manga-title data-work-id='\(w)'>漫画\(w)</h1><a data-chapter-id='1' href='/work/\(w)/1'>第1话</a><a data-chapter-id='2' href='/work/\(w)/2'>第2话</a>"
        responses[url.absoluteString] = textResponse(html, url)
        for c in 1...2 {
            let chapter = url.appendingPathComponent("\(c)")
            responses[chapter.absoluteString] = textResponse("<main data-manga-reader><img src='/img/\(w)-\(c).png'></main><main class='alternative'><img src='/other/\(w)-\(c).png'></main>", chapter)
            for prefix in ["img", "other"] {
                let image = URL(string: "https://a.test/\(prefix)/\(w)-\(c).png")!
                responses[image.absoluteString] = ResourceResponse(data: png, finalURL: image, statusCode: 200)
            }
        }
    }
    return (FixtureHTTPClient(responses), samples)
}
public let sourceDetectorChecks: [Check] = [
    Check("SourceDetectorTests.verifiedBindingIsReused") {
        let (client, samples) = try detectionFixtures(); let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
        let service = SourceService(store: store, registry: ParserRegistry(adapters: [HTMLTemplateAdapter()]), client: client, verifier: ImageVerifier())
        let report = try await service.add(name: "示例", baseURL: Samples.sourceA.baseURL, samples: samples)
        try expect(report.status == .verified, "Two works and two chapters each verified")
        let count = await client.requests.count
        try expect(count == 10, "Detail/chapter requests should be reused within detection")
        let a = try await service.adapter(for: report.sourceID); let b = try await service.adapter(for: report.sourceID)
        let after = await client.requests.count
        try expect(a.id == b.id && after == count, "Reuse binding without full detection")
    },
    Check("SourceDetectorTests.ambiguousContentRequiresChoice") {
        let (client, samples) = try detectionFixtures()
        var template = HTMLTemplate(); template.readerImages = ".alternative img"
        let registry = ParserRegistry(adapters: [HTMLTemplateAdapter(), HTMLTemplateAdapter(id: "alternative", template: template)])
        let report = await SourceDetector(registry: registry, client: client, verifier: ImageVerifier()).detect(source: Samples.sourceA, samples: samples)
        try expect(report.status == .ambiguous && report.binding == nil && report.candidates.count == 2, "Different readable bodies must not auto bind")
    },
    Check("SourceDetectorTests.accessFailureIsNotUnsupported") {
        let client = FixtureHTTPClient([Samples.sourceA.baseURL.absoluteString: ResourceResponse(data: Data(), finalURL: Samples.sourceA.baseURL, statusCode: 403)])
        let report = await SourceDetector(registry: ParserRegistry(adapters: [HTMLTemplateAdapter()]), client: client, verifier: ImageVerifier()).detect(source: Samples.sourceA, samples: [Samples.sourceA.baseURL])
        try expect(report.status == .accessFailure && report.error == .accessRestricted(403), "Access failure classification")
    },
    Check("SourceDetectorTests.cancelledDetectionCannotOverwriteNewBinding") {
        let (client, samples) = try detectionFixtures(); let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite")); try await store.save(source: Samples.sourceA)
        let service = SourceService(store: store, registry: ParserRegistry(adapters: [HTMLTemplateAdapter()]), client: client, verifier: ImageVerifier())
        let task = Task { try await service.retest(sourceID: Samples.sourceA.id, samples: samples) }; task.cancel()
        _ = try? await task.value
        try expect(try await store.source(id: Samples.sourceA.id)?.binding == nil, "Cancelled detection cannot commit a partial binding")
        var edited = Samples.sourceA; edited.baseURL = URL(string: "https://a.test/new/")!; try await store.save(source: edited)
        let result = try await store.save(binding: ParserBinding(parserID: "old"), sourceID: edited.id, expectedRevision: 0)
        try expect(!result, "Edited URL rejects previous detection")
    },
    Check("SourceDetectorTests.structureFailuresAndNetworkErrorsStayDistinct") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
        var source = Samples.sourceA; source.binding = ParserBinding(parserID: "html-declared-v1")
        try await store.save(source: source)
        let service = SourceService(store: store, registry: ParserRegistry(), client: FixtureHTTPClient([:]), verifier: ImageVerifier())
        try await service.recordResult(sourceID: source.id, error: .networkUnavailable)
        try expect(try await store.source(id: source.id)?.binding?.structureFailures == 0, "Network errors don't invalidate structure")
        try await service.recordResult(sourceID: source.id, error: .parseMismatch("missing reader"))
        try expect(try await store.source(id: source.id)?.binding?.needsRetest == false, "Single structural failure allows retry")
        try await service.recordResult(sourceID: source.id, error: .parseMismatch("missing reader"))
        try expect(try await store.source(id: source.id)?.binding?.needsRetest == true, "Two failures require retest")
    },
    Check("SourceDetectorTests.oldGenerationCannotOverwriteBinding") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
        try await store.save(source: Samples.sourceA)
        let old = try await store.beginDetection(sourceID: Samples.sourceA.id)
        let new = try await store.beginDetection(sourceID: Samples.sourceA.id)
        _ = try await store.commitDetection(binding: ParserBinding(parserID: "new"), sourceID: Samples.sourceA.id, expectedRevision: 0, works: [], generation: new)
        let applied = try await store.commitDetection(binding: ParserBinding(parserID: "old"), sourceID: Samples.sourceA.id, expectedRevision: 0, works: [], generation: old)
        let saved = try await store.source(id: Samples.sourceA.id)
        try expect(!applied && saved?.binding?.parserID == "new", "Old detection must not overwrite newer binding with same revision")
    },
    Check("SourceDetectorTests.limitedSamplesAreLabelled") {
        let (client, samples) = try detectionFixtures(works: 1)
        let report = await SourceDetector(registry: ParserRegistry(adapters: [HTMLTemplateAdapter()]), client: client, verifier: ImageVerifier()).detect(source: Samples.sourceA, samples: samples)
        try expect(report.status == .limited && report.binding?.level == .limited, "One work is limited validation")
    }
]
