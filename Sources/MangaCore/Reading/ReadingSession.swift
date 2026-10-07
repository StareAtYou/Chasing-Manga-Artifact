import Foundation
public struct ReaderState: Sendable {
    public let chapter: Chapter
    public let pages: [PageResource]
    public let offlineFiles: [PageID: URL]
    public let workID: WorkID?
    public var progress: ReadingProgress
    public var preferences: ReaderPreferences
    public var failedPages: [PageID: MangaError] = [:]
    public var sourceID: SourceID { chapter.id.sourceWorkID.sourceID }
}
public actor ReadingSession {
    private let store: LibraryStore
    private let sources: SourceService
    private let downloads: DownloadManager?
    private var generation = UUID()
    private var flushTask: Task<Void, Never>?
    private var prepared: [ChapterID: ReaderState] = [:]
    private var loading: [ChapterID: Task<ReaderState, Error>] = [:]
    public private(set) var state: ReaderState?
    public init(store: LibraryStore, sources: SourceService, downloads: DownloadManager? = nil) { self.store = store; self.sources = sources; self.downloads = downloads }
    public func open(chapter: Chapter, preferences: ReaderPreferences) async throws -> ReaderState {
        try await close(); let token = UUID(); generation = token
        let current = try await resolve(chapter: chapter, preferences: preferences)
        try Task.checkCancellation(); guard generation == token else { throw CancellationError() }
        state = current; prepared[chapter.id] = current; return current
    }
    /// Resolve an adjacent chapter without advancing history or the visible chapter.
    public func prepare(chapter: Chapter) async throws -> ReaderState {
        guard let active = state, chapter.id.sourceWorkID == active.chapter.id.sourceWorkID else { throw MangaError.chapterUnavailable }
        if let cached = prepared[chapter.id] { return cached }
        let token = generation
        let task = loading[chapter.id] ?? Task { try await self.resolve(chapter: chapter, preferences: active.preferences) }
        loading[chapter.id] = task
        do {
            let result = try await task.value
            try Task.checkCancellation(); guard generation == token else { throw CancellationError() }
            prepared[chapter.id] = result; loading[chapter.id] = nil; return result
        } catch {
            if generation == token { loading[chapter.id] = nil }
            throw error
        }
    }
    public func retainChapters(_ ids: Set<ChapterID>) {
        prepared = prepared.filter { ids.contains($0.key) || $0.key == state?.chapter.id }
    }
    private func resolve(chapter: Chapter, preferences: ReaderPreferences) async throws -> ReaderState {
        let pages: [PageResource]; var offline: [PageID: URL] = [:]
        if let downloads, let pair = try await downloads.offlineManifest(chapterID: chapter.id), pair.0.state == .completed {
            pages = pair.0.pages.sorted { $0.ordinal < $1.ordinal }
            offline = try await downloads.offlineFiles(chapterID: chapter.id)
        } else { pages = try await sources.pages(chapter: chapter) }
        guard !pages.isEmpty else { throw MangaError.parseMismatch("章节没有正文") }
        try Task.checkCancellation()
        let saved = try await store.progress(for: chapter.id.sourceWorkID)
        let progress = saved.flatMap { value in value.chapterID == chapter.id && pages.contains(where: { $0.id == value.pageID }) ? value : nil } ?? ReadingProgress(chapterID: chapter.id, pageID: pages[0].id)
        let workID = try await store.workID(for: chapter.id.sourceWorkID)
        return ReaderState(chapter: chapter, pages: pages, offlineFiles: offline, workID: workID, progress: progress, preferences: preferences)
    }
    public func recordPosition(pageID: PageID, fraction: Double) async throws {
        guard let active = state, var state = prepared[pageID.chapterID], state.pages.contains(where: { $0.id == pageID }) else { return }
        state.preferences = active.preferences
        state.progress = ReadingProgress(chapterID: state.chapter.id, pageID: pageID, fraction: fraction); self.state = state; prepared[state.chapter.id] = state
        flushTask?.cancel(); let token = generation
        flushTask = Task { do { try await Task.sleep(for: .milliseconds(300)); try await self.flush(token) } catch { } }
    }
    private func flush(_ token: UUID) async throws {
        try Task.checkCancellation(); guard token == generation, let state else { return }
        try await store.save(progress: state.progress)
        if let workID = state.workID { try await store.save(preferences: state.preferences, for: workID) }
    }
    public func changeMode(_ mode: ReadingMode) async throws { state?.preferences.mode = mode; try await flush(generation) }
    public func changeDirection(_ direction: ReadingDirection) async throws { state?.preferences.direction = direction; try await flush(generation) }
    public func changeBackground(_ background: AppTheme) async throws { state?.preferences.background = background; try await flush(generation) }
    public func recordFailure(pageID: PageID, error: MangaError?) {
        guard prepared[pageID.chapterID]?.pages.contains(where: { $0.id == pageID }) == true else { return }
        prepared[pageID.chapterID]?.failedPages[pageID] = error
        if state?.chapter.id == pageID.chapterID { state?.failedPages[pageID] = error }
    }
    public func close() async throws {
        flushTask?.cancel(); flushTask = nil
        for task in loading.values { task.cancel() }; loading.removeAll()
        try await flush(generation); generation = UUID(); state = nil; prepared.removeAll()
    }
}
