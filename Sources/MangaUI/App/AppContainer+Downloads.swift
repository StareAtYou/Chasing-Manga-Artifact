import Foundation
import MangaCore

public struct DownloadPreparationState: Identifiable, Sendable {
    public let sourceWorkID: SourceWorkID
    public var id: SourceWorkID { sourceWorkID }
    public var workTitle: String?
    public var isPreparing = true
    public var refreshingDirectory: Bool
    public var total = 0
    public var finished = 0
    public var existing = 0
    public var skipped = 0
    public var cancelled = false
    public var failure: String?
    public var errors: [ChapterID: String] = [:]
    public var chapterTitles: [ChapterID: String] = [:]
    var refreshedShelf = false
    let generation = UUID()
}

/// Bound page-list preparation across works while allowing two requests per work.
actor DownloadPreparationLimiter {
    private let limit: Int
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, any Error>)] = []
    init(limit: Int) { self.limit = limit }
    func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if active < limit { active += 1; continuation.resume() }
                else { waiting.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
    func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().1.resume() }
    }
}

private struct ChapterPreparationResult: Sendable {
    let chapter: Chapter
    var error: String?
    var cancelled = false
}

extension AppContainer {
    public func isPreparingDownloads(for id: SourceWorkID) -> Bool {
        downloadPreparations[id]?.isPreparing == true
    }
    public func queueDownload(_ chapter: Chapter) async throws {
        try await queueDownload(chapter, epoch: downloads.preparationEpoch(for: chapter.id.sourceWorkID), refreshAfter: true)
    }
    private func queueDownload(_ chapter: Chapter, epoch: UUID, refreshAfter: Bool) async throws {
        try Task.checkCancellation()
        guard !preparingChapters.contains(chapter.id) else { return }
        preparingChapters.insert(chapter.id); defer { preparingChapters.remove(chapter.id) }
        try await preparationLimiter.acquire()
        do {
            try Task.checkCancellation()
            let existing = try await downloads.task(chapterID: chapter.id)
            try Task.checkCancellation()
            if let existing, existing.state != .cancelled {
                if [.failed, .paused].contains(existing.state) { try await downloads.retry(taskID: existing.id, preparationEpoch: epoch) }
                else { try await store.ensureDownloadShelfOwner(for: chapter.id.sourceWorkID, expectedEpoch: epoch) }
            } else {
                guard chapter.access == .available else { throw MangaError.chapterUnavailable }
                let pages = try await sources.pages(chapter: chapter, priority: .download)
                try Task.checkCancellation()
                _ = try await downloads.enqueue(chapter: chapter, pages: pages, preparationEpoch: epoch)
            }
            await preparationLimiter.release()
        } catch {
            await preparationLimiter.release()
            throw error
        }
        if refreshAfter { try await refresh() }
    }
    private func prepareDownloads(_ chapters: [Chapter], id: SourceWorkID, epoch: UUID) async {
        downloadPreparations[id]?.total = chapters.count
        await withTaskGroup(of: ChapterPreparationResult.self) { group in
            var pending = chapters.makeIterator()
            func submit(_ chapter: Chapter) {
                group.addTask {
                    do {
                        try await self.queueDownload(chapter, epoch: epoch, refreshAfter: false)
                        return ChapterPreparationResult(chapter: chapter)
                    } catch is CancellationError {
                        return ChapterPreparationResult(chapter: chapter, cancelled: true)
                    } catch {
                        return ChapterPreparationResult(chapter: chapter, error: error.localizedDescription)
                    }
                }
            }
            for _ in 0..<2 { if let chapter = pending.next(), !Task.isCancelled { submit(chapter) } }
            while let result = await group.next() {
                if result.cancelled || Task.isCancelled {
                    downloadPreparations[id]?.cancelled = true
                    group.cancelAll()
                    continue
                }
                downloadPreparations[id]?.finished += 1
                if let error = result.error {
                    downloadPreparations[id]?.errors[result.chapter.id] = error
                    downloadPreparations[id]?.chapterTitles[result.chapter.id] = result.chapter.title
                } else if downloadPreparations[id]?.refreshedShelf == false {
                    // Enqueue can add a discovery work to the shelf. Publish that
                    // card once, even while later chapter parsing is still pending.
                    downloadPreparations[id]?.refreshedShelf = true
                    do { try await refresh() } catch { if !Task.isCancelled { message = error.localizedDescription } }
                }
                if let chapter = pending.next(), !Task.isCancelled { submit(chapter) }
            }
        }
    }
    private func launchPreparation(for id: SourceWorkID, chapters selected: [Chapter]? = nil) -> Task<Void, Never>? {
        guard !isPreparingDownloads(for: id), !Task.isCancelled else { return nil }
        // Reserve synchronously: a second tap cannot start before this task runs.
        downloadPreparations[id] = DownloadPreparationState(sourceWorkID: id, workTitle: catalog.first { $0.id == id }?.title, refreshingDirectory: selected == nil)
        let generation = downloadPreparations[id]!.generation
        let task = Task { @MainActor in
            do {
                let epoch = try await downloads.preparationEpoch(for: id)
                try Task.checkCancellation()
                let chapters: [Chapter]
                if let selected { chapters = selected }
                else {
                    guard let work = try await store.sourceWork(id: id) else { throw MangaError.chapterUnavailable }
                    downloadPreparations[id]?.workTitle = work.title
                    let fetched = try await sources.loadWork(url: work.url, sourceID: id.sourceID)
                    try Task.checkCancellation()
                    guard fetched.work.id == id else { throw MangaError.parseMismatch("刷新目录返回了其他作品，请重新打开作品后重试") }
                    try await store.save(sourceWork: fetched.work, chapters: fetched.chapters)
                    try Task.checkCancellation()
                    let existing = Set(try await downloads.tasks().filter { [.completed, .running, .queued].contains($0.state) }.map { $0.chapter.id })
                    var seen = Set<ChapterID>()
                    let ordered = fetched.chapters.sorted { $0.ordinal < $1.ordinal }.filter { seen.insert($0.id).inserted }
                    downloadPreparations[id]?.skipped = ordered.filter { $0.access != .available }.count
                    let available = ordered.filter { $0.access == .available }
                    downloadPreparations[id]?.existing = available.filter { existing.contains($0.id) }.count
                    chapters = available.filter { !existing.contains($0.id) }
                }
                downloadPreparations[id]?.refreshingDirectory = false
                await prepareDownloads(chapters, id: id, epoch: epoch)
            } catch is CancellationError { downloadPreparations[id]?.cancelled = true }
            catch { downloadPreparations[id]?.failure = error.localizedDescription; message = error.localizedDescription }
            // Refresh final task states after the first queued chapter published the shelf.
            do { try await refresh() } catch { if !Task.isCancelled { message = error.localizedDescription } }
            guard downloadPreparations[id]?.generation == generation else { return }
            if Task.isCancelled { downloadPreparations[id]?.cancelled = true }
            downloadPreparations[id]?.isPreparing = false
            preparationTasks[id] = nil
        }
        preparationTasks[id] = task
        return task
    }
    private func waitForPreparation(_ task: Task<Void, Never>, id: SourceWorkID) async {
        let generation = downloadPreparations[id]?.generation
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor in
                if self.downloadPreparations[id]?.generation == generation { task.cancel() }
            }
        }
    }
    public func queueDownloads(_ chapters: [Chapter]) async {
        let groups = Dictionary(grouping: chapters, by: { $0.id.sourceWorkID })
        let tasks = groups.compactMap { id, chapters in launchPreparation(for: id, chapters: chapters).map { (id, $0) } }
        for (id, task) in tasks { await waitForPreparation(task, id: id) }
    }
    /// Refresh only the requested source's complete directory.
    public func queueWholeWork(_ id: SourceWorkID) async {
        guard let task = launchPreparation(for: id) else { return }
        await waitForPreparation(task, id: id)
    }
    public func startBatch(_ chapters: [Chapter]) {
        for (id, selected) in Dictionary(grouping: chapters, by: { $0.id.sourceWorkID }) {
            _ = launchPreparation(for: id, chapters: selected)
        }
    }
    public func startWholeDownload(_ id: SourceWorkID) { _ = launchPreparation(for: id) }
    public func cancelPreparation(sourceWorkIDs: Set<SourceWorkID>? = nil) {
        for (id, task) in preparationTasks where sourceWorkIDs?.contains(id) ?? true {
            downloadPreparations[id]?.cancelled = true
            task.cancel()
        }
    }
}
