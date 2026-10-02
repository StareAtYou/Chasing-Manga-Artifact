import Foundation
import MangaCore
public actor ImagePipeline {
    public typealias Refresh = @Sendable (PageResource, SourceID) async throws -> PageResource
    private struct Job { let id: UUID; let priority: RequestPriority; let task: Task<URL, Error> }
    private struct Decoded { let tiles: [ImageTile]; let bytes: Int; let accessed: Date }
    private let client: any HTTPClient
    public let files: PageFileStore
    private let verifier: any ImageVerifying
    private let refresh: Refresh?
    private let memoryLimit: Int
    private var jobs: [PageID: Job] = [:]
    private var readers: [PageID: [UUID: UUID]] = [:]
    private var decoded: [String: Decoded] = [:]
    private var prefetchWindow = 3
    public var decodedCacheBytes: Int { decoded.values.reduce(0) { $0 + $1.bytes } }
    public var prefetchCount: Int { jobs.values.filter { $0.priority == .prefetch }.count }
    public init(client: any HTTPClient, files: PageFileStore, verifier: any ImageVerifying = ImageVerifier(), memoryLimit: Int = 64 * 1024 * 1024, refresh: Refresh? = nil) {
        self.client = client; self.files = files; self.verifier = verifier; self.memoryLimit = max(1, memoryLimit); self.refresh = refresh
    }
    public func file(for page: PageResource, sourceID: SourceID, priority: RequestPriority = .reading) async throws -> URL {
        try Task.checkCancellation()
        if let cached = await files.cachedFile(for: page.id) {
            if (try? verifier.verify(Data(contentsOf: cached))) != nil { return cached }
            try await files.remove(pageID: page.id)
        }
        if let old = jobs[page.id], old.priority > priority || old.task.isCancelled { old.task.cancel(); jobs.removeValue(forKey: page.id) }
        let job = jobs[page.id] ?? start(page, sourceID: sourceID, priority: priority)
        let consumer = UUID(); readers[page.id, default: [:]][consumer] = job.id
        defer { releaseReader(page.id, consumer: consumer, cancel: false) }
        return try await withTaskCancellationHandler {
            let result = try await job.task.value; try Task.checkCancellation(); return result
        } onCancel: { Task { await self.releaseReader(page.id, consumer: consumer, cancel: true) } }
    }
    private func releaseReader(_ pageID: PageID, consumer: UUID, cancel: Bool) {
        guard let token = readers[pageID]?.removeValue(forKey: consumer) else { return }
        if readers[pageID]?.isEmpty == true { readers.removeValue(forKey: pageID) }
        if cancel, let job = jobs[pageID], job.id == token, readers[pageID]?.values.contains(token) != true { job.task.cancel() }
    }
    @discardableResult private func start(_ page: PageResource, sourceID: SourceID, priority: RequestPriority) -> Job {
        let client = self.client; let files = self.files; let verifier = self.verifier; let refresh = self.refresh
        let token = UUID()
        let task = Task<URL, Error> {
            var current = page
            if let expires = current.expiresAt, expires <= Date(), let refresh { current = try await refresh(current, sourceID) }
            let response: ResourceResponse
            do { response = try await client.send(current.request, sourceID: sourceID, priority: priority) }
            catch MangaError.accessRestricted(let status) where [401, 403].contains(status) {
                guard let refresh else { throw MangaError.accessRestricted(status) }
                current = try await refresh(current, sourceID); response = try await client.send(current.request, sourceID: sourceID, priority: priority)
            }
            guard current.id == page.id else { throw MangaError.parseMismatch("刷新改变了页面身份") }
            try Task.checkCancellation(); _ = try verifier.verify(response.data)
            return try await files.writeCache(data: response.data, pageID: page.id)
        }
        let job = Job(id: token, priority: priority, task: task); jobs[page.id] = job
        Task { _ = try? await task.value; self.finished(page.id, token: token) }
        return job
    }
    private func finished(_ pageID: PageID, token: UUID) { if jobs[pageID]?.id == token { jobs.removeValue(forKey: pageID) } }
    public func prefetch(_ pages: [PageResource], sourceID: SourceID) async {
        for page in pages.prefix(prefetchWindow) where jobs[page.id] == nil {
            if await files.cachedFile(for: page.id) == nil { start(page, sourceID: sourceID, priority: .prefetch) }
        }
    }
    public func cancelPrefetch(chapterID: ChapterID) {
        for (id, job) in jobs where id.chapterID == chapterID && job.priority == .prefetch { job.task.cancel(); jobs.removeValue(forKey: id) }
    }
    public func tiles(file: URL, pageID: PageID, viewport: PixelRect, targetWidth: Int) async throws -> [ImageTile] {
        let key = "\(pageID.key):\(viewport):\(targetWidth)"
        if let entry = decoded[key] { return entry.tiles }
        let tiles = try await Task.detached(priority: .userInitiated) { try TiledImageDecoder().decode(file: file, viewport: viewport, targetWidth: targetWidth) }.value
        try Task.checkCancellation()
        let bytes = tiles.reduce(0) { $0 + $1.decodedBytes }
        if bytes <= memoryLimit {
            decoded[key] = Decoded(tiles: tiles, bytes: bytes, accessed: Date())
            for (oldKey, _) in decoded.sorted(by: { $0.value.accessed < $1.value.accessed }) where decodedCacheBytes > memoryLimit { decoded.removeValue(forKey: oldKey) }
        }
        return tiles
    }
    public func handleMemoryPressure() { decoded.removeAll(); prefetchWindow = 1; for (id, job) in jobs where job.priority == .prefetch { job.task.cancel(); jobs.removeValue(forKey: id) } }
    public func leave(chapterID: ChapterID) { cancelPrefetch(chapterID: chapterID); decoded = decoded.filter { !$0.key.hasPrefix(chapterID.key) } }
}
