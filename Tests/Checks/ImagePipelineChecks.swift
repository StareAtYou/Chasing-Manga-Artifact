import Foundation
import MangaCore
import MangaPlatform
actor ImageBlockingTransport: HTTPTransport {
    let data: Data
    var paths: [String] = []
    var gates: [CheckedContinuation<Void, Never>] = []
    init(data: Data) { self.data = data }
    func load(_ request: URLRequest) async throws -> ResourceResponse {
        paths.append(request.url!.path)
        await withCheckedContinuation { gates.append($0) }
        try Task.checkCancellation()
        return ResourceResponse(data: data, finalURL: request.url!, statusCode: 200)
    }
    func release() { if !gates.isEmpty { gates.removeFirst().resume() } }
}
public let imagePipelineChecks: [Check] = [
    Check("ImagePipelineTests.readingPreemptsPrefetch") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let transport = ImageBlockingTransport(data: try generatedPNG()); let client = URLSessionHTTPClient(transport: transport, scheduler: RequestScheduler(globalLimit: 1, sourceLimit: 1))
        let pipeline = ImagePipeline(client: client, files: try PageFileStore(root: directory))
        let chapter = Samples.chapter(Samples.work()); let pages = Samples.pages(chapter, count: 5)
        await pipeline.prefetch(Array(pages.prefix(3)), sourceID: Samples.sourceA.id)
        while await transport.paths.isEmpty { await Task.yield() }
        let read = Task { try await pipeline.file(for: pages[4], sourceID: Samples.sourceA.id) }
        for _ in 0..<500 { await Task.yield() }
        await transport.release()
        while await transport.paths.count < 2 { await Task.yield() }
        try expect(await transport.paths[1] == pages[4].request.url.path, "Visible page precedes queued prefetch")
        await transport.release(); _ = try await read.value
        await pipeline.cancelPrefetch(chapterID: chapter.id)
        // A fake transport gate is not cooperatively cancellable; release its held request.
        await transport.release()
    },
    Check("ImagePipelineTests.cancelPrefetchReleasesResources") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let transport = ImageBlockingTransport(data: try generatedPNG()); let pipeline = ImagePipeline(client: URLSessionHTTPClient(transport: transport), files: try PageFileStore(root: directory))
        let chapter = Samples.chapter(Samples.work()); let pages = Samples.pages(chapter)
        await pipeline.prefetch(pages, sourceID: Samples.sourceA.id)
        while await transport.paths.count < 2 { await Task.yield() }
        await pipeline.cancelPrefetch(chapterID: chapter.id)
        await transport.release(); await transport.release()
        for _ in 0..<500 { await Task.yield() }
        try expect(await pipeline.prefetchCount == 0, "Leaving chapter releases prefetch bookkeeping")
    },
    Check("ImagePipelineTests.longImageHasBoundedTiles") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("long.png"); try generatedPNG(width: 100, height: 20_000).write(to: file)
        let tiles = try TiledImageDecoder().decode(file: file, viewport: PixelRect(x: 0, y: 0, width: 100, height: 20_000), targetWidth: 100)
        try expect(tiles.count >= 5 && tiles.allSatisfy { $0.frame.height <= 4096 && $0.image.height <= 4096 }, "Bound original tile dimensions and decoder fallback dimensions")
        try expect(tiles.reduce(0) { $0 + $1.decodedBytes } <= 64 * 1024 * 1024, "Bound decoded tile budget")
    },
    Check("ImagePipelineTests.sameSignedPageSharesCacheKey") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let files = try PageFileStore(root: directory); let page = Samples.pages(Samples.chapter(Samples.work()))[0]
        let old = try await files.writeCache(data: generatedPNG(), pageID: page.id)
        var refreshed = page; refreshed.request.url = URL(string: "https://images.test/new.png?sign=new")!
        try expect(await files.cachedFile(for: refreshed.id) == old, "Cache key follows stable PageID")
    },
    Check("ImagePipelineTests.invalidDataNeverCachedAsReadable") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let files = try PageFileStore(root: directory); let page = Samples.pages(Samples.chapter(Samples.work()))[0]
        do { _ = try await files.writeCache(data: Data("<html>error</html>".utf8), pageID: page.id); throw CheckFailure(description: "Reject invalid image") } catch MangaError.invalidImage { }
        try expect(await files.cachedFile(for: page.id) == nil, "Do not cache error pages")
    },
    Check("ImagePipelineTests.memoryPressureClearsDecodedCache") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let files = try PageFileStore(root: directory); let page = Samples.pages(Samples.chapter(Samples.work()))[0]
        let file = try await files.writeCache(data: generatedPNG(), pageID: page.id)
        let pipeline = ImagePipeline(client: FixtureHTTPClient([:]), files: files)
        _ = try await pipeline.tiles(file: file, pageID: page.id, viewport: PixelRect(x: 0, y: 0, width: 16, height: 24), targetWidth: 16)
        try expect(await pipeline.decodedCacheBytes > 0, "Decoded data cached")
        await pipeline.handleMemoryPressure()
        try expect(await pipeline.decodedCacheBytes == 0, "Memory pressure clears decoded data")
    }
]
