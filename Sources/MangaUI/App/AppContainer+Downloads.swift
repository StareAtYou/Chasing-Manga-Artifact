import Foundation
import MangaCore
extension AppContainer {
    public func queueDownload(_ chapter: Chapter) async throws {
        guard !preparingChapters.contains(chapter.id) else { return }
        if let existing = try await downloads.tasks().first(where: { $0.chapter.id == chapter.id && $0.state != .cancelled }) {
            if [.failed, .paused].contains(existing.state) { try await downloads.retry(taskID: existing.id) }
            try await refresh(); return
        }
        guard chapter.access == .available else { throw MangaError.chapterUnavailable }
        preparingChapters.insert(chapter.id); defer { preparingChapters.remove(chapter.id) }
        let pages = try await sources.pages(chapter: chapter, priority: .download)
        try Task.checkCancellation(); _ = try await downloads.enqueue(chapter: chapter, pages: pages); try await refresh()
    }
    public func queueDownloads(_ chapters: [Chapter]) async {
        guard !preparingBatch else { return }
        preparingBatch = true; preparationTotal = chapters.count; preparationFinished = 0; preparationErrors = [:]
        defer { preparingBatch = false }
        for chapter in chapters {
            if Task.isCancelled { break }
            do { try await queueDownload(chapter) }
            catch is CancellationError { break }
            catch { preparationErrors[chapter.id] = error.localizedDescription }
            preparationFinished += 1
        }
    }
    public func startBatch(_ chapters: [Chapter]) {
        guard !preparingBatch else { return }
        batchTask = Task { @MainActor in await queueDownloads(chapters) }
    }
    public func cancelPreparation() { batchTask?.cancel() }
}
