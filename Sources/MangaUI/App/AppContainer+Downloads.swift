import Foundation
import MangaCore
extension AppContainer {
    public func queueDownload(_ chapter: Chapter) async throws {
        try Task.checkCancellation()
        guard !preparingChapters.contains(chapter.id) else { return }
        preparingChapters.insert(chapter.id); defer { preparingChapters.remove(chapter.id) }
        let existing = try await downloads.tasks().first(where: { $0.chapter.id == chapter.id && $0.state != .cancelled })
        try Task.checkCancellation()
        if let existing {
            if [.failed, .paused].contains(existing.state) { try await downloads.retry(taskID: existing.id) }
            try await refresh(); return
        }
        guard chapter.access == .available else { throw MangaError.chapterUnavailable }
        let pages = try await sources.pages(chapter: chapter, priority: .download)
        try Task.checkCancellation(); _ = try await downloads.enqueue(chapter: chapter, pages: pages); try await refresh()
    }
    private func resetPreparation(title: String? = nil) {
        preparingBatch = true; preparationTotal = 0; preparationFinished = 0; preparationErrors = [:]; preparationChapterTitles = [:]
        preparationFailure = nil; preparationWorkTitle = title; preparationSkipped = 0; preparationExisting = 0; preparationCancelled = false
    }
    private func prepareDownloads(_ chapters: [Chapter]) async {
        preparationTotal = chapters.count
        for chapter in chapters {
            if Task.isCancelled { preparationCancelled = true; break }
            do { try await queueDownload(chapter) }
            catch is CancellationError { preparationCancelled = true; break }
            catch { preparationErrors[chapter.id] = error.localizedDescription; preparationChapterTitles[chapter.id] = chapter.title }
            preparationFinished += 1
        }
    }
    public func queueDownloads(_ chapters: [Chapter]) async {
        guard !preparingBatch, !Task.isCancelled else { return }
        resetPreparation()
        defer { preparingBatch = false }
        await prepareDownloads(chapters)
    }
    /// Refresh the selected source's full directory. Never use the filtered UI
    /// list or silently include another associated source's chapters.
    public func queueWholeWork(_ id: SourceWorkID) async {
        guard !preparingBatch, !Task.isCancelled else { return }
        resetPreparation(title: "整部漫画")
        defer { preparingBatch = false }
        do {
            guard let work = try await store.sourceWork(id: id) else { throw MangaError.chapterUnavailable }
            preparationWorkTitle = work.title
            let fetched = try await sources.loadWork(url: work.url, sourceID: id.sourceID)
            try Task.checkCancellation()
            guard fetched.work.id == id else { throw MangaError.parseMismatch("刷新目录返回了其他作品，请重新打开作品后重试") }
            try await store.save(sourceWork: fetched.work, chapters: fetched.chapters)
            try await refresh()
            let existing = Set(try await downloads.tasks().filter { [.completed, .running, .queued].contains($0.state) }.map { $0.chapter.id })
            var seen = Set<ChapterID>()
            let chapters = fetched.chapters.sorted { $0.ordinal < $1.ordinal }.filter { seen.insert($0.id).inserted }
            preparationSkipped = chapters.filter { $0.access != .available }.count
            let available = chapters.filter { $0.access == .available }
            preparationExisting = available.filter { existing.contains($0.id) }.count
            await prepareDownloads(available.filter { !existing.contains($0.id) })
        } catch is CancellationError { preparationCancelled = true }
        catch { preparationFailure = error.localizedDescription; message = error.localizedDescription }
    }
    public func startBatch(_ chapters: [Chapter]) {
        guard !preparingBatch, batchTask == nil else { return }
        batchTask = Task { @MainActor in
            defer { batchTask = nil }
            await queueDownloads(chapters)
        }
    }
    public func startWholeDownload(_ id: SourceWorkID) {
        guard !preparingBatch, batchTask == nil else { return }
        batchTask = Task { @MainActor in
            defer { batchTask = nil }
            await queueWholeWork(id)
        }
    }
    public func cancelPreparation() { batchTask?.cancel() }
}
