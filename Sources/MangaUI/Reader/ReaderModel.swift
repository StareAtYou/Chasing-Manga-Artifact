import SwiftUI
import Observation
import MangaCore
import MangaPlatform
struct ReaderScrollRequest: Hashable { let token = UUID(); let pageID: PageID; let fraction: Double }
@MainActor @Observable final class ReaderModel {
    let app: AppContainer
    private let entryChapterID: ChapterID
    var chapterID: ChapterID { state?.chapter.id ?? entryChapterID }
    let session: ReadingSession
    var state: ReaderState?
    var error: String?
    var directory: [Chapter] = []
    var scrollChapters: [ReaderState] = []
    var adjacentLoading = Set<Int>()
    var adjacentErrors: [Int: String] = [:]
    @ObservationIgnored private var errorChapters: [Int: ChapterID] = [:]
    @ObservationIgnored var viewportAnchor: ReadingProgress?
    @ObservationIgnored private var positionTask: Task<Void, Never>?
    @ObservationIgnored private var closed = false
    var restoring = true
    var scrollRequest: ReaderScrollRequest?
    var readyPages = Set<PageID>()
    var isReady: Bool { !restoring && state != nil }
    func requestScroll(pageID: PageID, fraction: Double = 0) { restoring = true; scrollRequest = ReaderScrollRequest(pageID: pageID, fraction: fraction) }
    func pageReady(_ pageID: PageID) { readyPages.insert(pageID) }
    func offlineFile(for pageID: PageID) -> URL? { scrollChapters.first { $0.chapter.id == pageID.chapterID }?.offlineFiles[pageID] ?? state?.offlineFiles[pageID] }
    func stepPages(visualDelta: Int) {
        guard !restoring, let state, let next = PageLayout.destination(from: state.progress.pageID, pageIDs: state.pages.map(\.id), mode: state.preferences.mode, direction: state.preferences.direction, visualDelta: visualDelta) else { return }
        position(next, fraction: 0, mode: state.preferences.mode)
        if state.preferences.mode == .scroll { requestScroll(pageID: next) }
    }
    init(app: AppContainer, chapterID: ChapterID) { self.app = app; entryChapterID = chapterID; session = ReadingSession(store: app.store, sources: app.sources, downloads: app.downloads) }
    func load() async {
        do {
            guard let chapter = try await app.store.chapter(id: entryChapterID) else { throw MangaError.chapterUnavailable }
            let workID = try await app.store.workID(for: entryChapterID.sourceWorkID)
            let preferences: ReaderPreferences
            if let workID { preferences = try await app.store.preferences(for: workID) } else { preferences = ReaderPreferences() }
            let opened = try await session.open(chapter: chapter, preferences: preferences)
            guard !closed else { return }
            state = opened; scrollChapters = [opened]
            directory = try await app.store.chapters(for: entryChapterID.sourceWorkID)
            try await app.updates.markRead(chapterID: entryChapterID); error = nil
        } catch is CancellationError { } catch { if !closed { self.error = error.localizedDescription } }
    }
    func adjacentChapter(_ delta: Int) -> Chapter? {
        guard delta == -1 || delta == 1, let edge = delta < 0 ? scrollChapters.first : scrollChapters.last,
              let index = directory.firstIndex(where: { $0.id == edge.chapter.id }), directory.indices.contains(index + delta) else { return nil }
        return directory[index + delta]
    }
    func loadAdjacent(_ delta: Int, retry: Bool = false) async {
        guard !closed, !restoring, state?.preferences.mode == .scroll,
              !adjacentLoading.contains(delta), retry || adjacentErrors[delta] == nil,
              let chapter = adjacentChapter(delta),
              scrollChapters.count < 3 || (delta < 0 ? scrollChapters.first : scrollChapters.last)?.chapter.id == chapterID else { return }
        adjacentLoading.insert(delta); adjacentErrors[delta] = nil
        defer { adjacentLoading.remove(delta) }
        do {
            let prepared = try await session.prepare(chapter: chapter)
            try Task.checkCancellation()
            guard !closed, state?.preferences.mode == .scroll, adjacentChapter(delta)?.id == chapter.id,
                  scrollChapters.count < 3 || (delta < 0 ? scrollChapters.first : scrollChapters.last)?.chapter.id == chapterID else { return }
            if delta < 0 { scrollChapters.insert(prepared, at: 0) } else { scrollChapters.append(prepared) }
            // Keep a bounded chapter window. Preserve the visible anchor when content above it changes.
            var removed: [ReaderState] = []
            if scrollChapters.count > 3 {
                if delta > 0, scrollChapters.first?.chapter.id != chapterID { removed.append(scrollChapters.removeFirst()) }
                else if delta < 0, scrollChapters.last?.chapter.id != chapterID { removed.append(scrollChapters.removeLast()) }
            }
            if delta < 0 || !removed.isEmpty, let active = state?.progress {
                let progress = viewportAnchor.flatMap { anchor in scrollChapters.contains { $0.chapter.id == anchor.chapterID } ? anchor : nil } ?? active
                requestScroll(pageID: progress.pageID, fraction: progress.fraction)
            }
            let kept = Set(scrollChapters.map(\.chapter.id))
            for direction in [-1, 1] where errorChapters[direction] != adjacentChapter(direction)?.id { adjacentErrors[direction] = nil; errorChapters[direction] = nil }
            readyPages = readyPages.filter { kept.contains($0.chapterID) }
            await session.retainChapters(kept)
            for old in removed { await app.images.leave(chapterID: old.chapter.id) }
        } catch is CancellationError { } catch { if !closed, adjacentChapter(delta)?.id == chapter.id { adjacentErrors[delta] = error.localizedDescription; errorChapters[delta] = chapter.id } }
    }
    func position(_ id: PageID, fraction: Double, mode: ReadingMode) {
        guard !closed, !restoring, let active = state, active.preferences.mode == mode,
              let index = scrollChapters.firstIndex(where: { $0.chapter.id == id.chapterID }), scrollChapters[index].pages.contains(where: { $0.id == id }) else { return }
        let changedChapter = active.chapter.id != id.chapterID
        let moved = active.progress.pageID != id
        var selected = scrollChapters[index]; selected.preferences = active.preferences
        selected.progress = ReadingProgress(chapterID: id.chapterID, pageID: id, fraction: fraction)
        scrollChapters[index] = selected; state = selected
        if mode != .scroll && moved { restoring = true }
        let previous = positionTask
        positionTask = Task {
            await previous?.value
            await app.perform {
                try await session.recordPosition(pageID: id, fraction: fraction)
                if changedChapter { try await app.updates.markRead(chapterID: id.chapterID) }
            }
            if let index = selected.pages.firstIndex(where: { $0.id == id }), selected.offlineFiles.isEmpty { await app.images.prefetch(Array(selected.pages.dropFirst(index + 1).prefix(3)), sourceID: selected.sourceID) }
        }
    }
    func mode(_ value: ReadingMode) async { guard state?.preferences.mode != value else { return }; restoring = true; await positionTask?.value; await app.perform { try await session.changeMode(value); state = await session.state } }
    func direction(_ value: ReadingDirection) async { await positionTask?.value; await app.perform { try await session.changeDirection(value); state = await session.state } }
    func background(_ value: AppTheme) async { await positionTask?.value; await app.perform { try await session.changeBackground(value); state = await session.state } }
    func close() async {
        guard !closed else { return }; closed = true
        await positionTask?.value; positionTask = nil
        await app.perform { try await session.close(); try await app.refresh() }
        for chapter in scrollChapters { await app.images.leave(chapterID: chapter.chapter.id) }
    }
    func navigate(_ delta: Int) { guard let index = directory.firstIndex(where: { $0.id == chapterID }), directory.indices.contains(index + delta) else { return }; if !app.path.isEmpty { app.path.removeLast() }; app.path.append(.reader(directory[index + delta].id)) }
}
