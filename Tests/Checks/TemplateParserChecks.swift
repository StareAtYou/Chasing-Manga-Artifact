import Foundation
import MangaCore
import MangaPlatform
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public actor FixtureHTTPClient: HTTPClient {
    public var responses: [String: ResourceResponse]
    public var requests: [ResourceRequest] = []
    public init(_ responses: [String: ResourceResponse]) { self.responses = responses }
    public func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        requests.append(request)
        guard let response = responses[request.url.absoluteString] else { throw MangaError.chapterUnavailable }
        guard (200..<300).contains(response.statusCode) else { throw MangaError.accessRestricted(response.statusCode) }
        return response
    }
}
public func textResponse(_ text: String, _ url: URL) -> ResourceResponse { ResourceResponse(data: Data(text.utf8), finalURL: url, statusCode: 200) }
public func generatedPNG(width: Int = 16, height: Int = 24) throws -> Data {
    let bytes = [UInt8](repeating: 255, count: width * height * 4)
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CheckFailure(description: "PNG generation") }
    return data as Data
}
public let templateParserChecks: [Check] = [
    Check("TemplateParserTests.readerImagesExcludeAdsAndCovers") {
        let chapter = Samples.chapter(Samples.work()); let html = try String(contentsOf: Bundle.module.url(forResource: "template-reader", withExtension: "html", subdirectory: "Fixtures")!, encoding: .utf8)
        let client = FixtureHTTPClient([chapter.url.absoluteString: textResponse(html, chapter.url)])
        let pages = try await HTMLTemplateAdapter().pages(chapter: chapter, context: ParserContext(source: Samples.sourceA, client: client))
        try expect(pages.map { $0.request.url.lastPathComponent } == ["one.png", "two.png"], "Only reader images in document order")
        try expect(pages[0].request.referer == chapter.url, "Preserve reader request context")
    },
    Check("TemplateParserTests.followsChapterPaginationWithoutLoops") {
        let chapter = Samples.chapter(Samples.work()); let second = URL(string: "https://a.test/chapter/1?page=2")!
        let firstHTML = "<main data-manga-reader><img src='/one.png'></main><a data-reader-next href='\(second.absoluteString)'>next</a>"
        let lastHTML = "<main data-manga-reader><img src='/one.png'><img src='/two.png'></main><a data-reader-next href='\(chapter.url.absoluteString)'>next</a>"
        let client = FixtureHTTPClient([chapter.url.absoluteString: textResponse(firstHTML, chapter.url), second.absoluteString: textResponse(lastHTML, second)])
        let pages = try await HTMLTemplateAdapter().pages(chapter: chapter, context: ParserContext(source: Samples.sourceA, client: client))
        try expect(pages.count == 2 && pages.last?.ordinal == 1, "Deduplicate pages and terminate loops")
        try expect(await client.requests.count == 2, "Loop must not trigger extra requests")
    },
    Check("TemplateParserTests.semanticImageQueriesRemainDistinct") {
        let chapter = Samples.chapter(Samples.work())
        let html = "<main data-manga-reader><img src='/image?id=10&amp;sign=old'><img src='/image?id=11&amp;sign=new'></main>"
        let client = FixtureHTTPClient([chapter.url.absoluteString: textResponse(html, chapter.url)])
        let pages = try await HTMLTemplateAdapter().pages(chapter: chapter, context: ParserContext(source: Samples.sourceA, client: client))
        try expect(pages.count == 2 && pages[0].id != pages[1].id, "Image IDs in query parameters must remain distinct")
    },
    Check("TemplateParserTests.jsonTemplateRequiresKnownSchema") {
        let chapter = Samples.chapter(Samples.work())
        let valid = "{\"schemaVersion\":1,\"pages\":[{\"id\":\"a\",\"ordinal\":0,\"url\":\"/one.png\"}]}"
        let adapter = JSONTemplateAdapter()
        let context = ParserContext(source: Samples.sourceA, client: FixtureHTTPClient([chapter.url.absoluteString: textResponse(valid, chapter.url)]))
        let pages = try await adapter.pages(chapter: chapter, context: context)
        try expect(pages.count == 1 && pages[0].id.externalID == "a", "Known schema preserves explicit identity")
        do {
            _ = try await adapter.pages(chapter: chapter, context: ParserContext(source: Samples.sourceA, client: FixtureHTTPClient([chapter.url.absoluteString: textResponse("{\"images\":[\"/one.png\"]}", chapter.url)])))
            throw CheckFailure(description: "Unknown schema should fail")
        } catch MangaError.parseMismatch { }
    }
]
public let imageVerifierChecks: [Check] = [
    Check("ImageVerifierTests.htmlIsNotAnImage") {
        try expectError { _ = try ImageVerifier().verify(Data("<html>200 captcha</html>".utf8)) }
        let metadata = try ImageVerifier().verify(generatedPNG())
        try expect(metadata.width == 16 && metadata.height == 24, "Decode actual generated PNG")
    },
    Check("ImageVerifierTests.truncatedImageRejected") {
        let valid = try generatedPNG()
        try expectError { _ = try ImageVerifier().verify(Data(valid.prefix(valid.count / 2))) }
    }
]
