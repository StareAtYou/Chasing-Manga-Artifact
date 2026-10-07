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
    @ObservationIgnored var visibleChapterIDs = Set<ChapterID>()
    private var pageAspects: [PageID: Double] = [:]
    func aspect(for id: PageID) -> Double { pageAspects[id] ?? 1.4 }
    func pageAspect(_ value: Double, for id: PageID) { if value.isFinite, value > 0, pageAspects[id] != value { pageAspects[id] = value } }
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
            let removed = removeOffscreenChapters(prefer: delta)
            await releaseChapters(removed)
        } catch is CancellationError { } catch { if !closed, adjacentChapter(delta)?.id == chapter.id { adjacentErrors[delta] = error.localizedDescription; errorChapters[delta] = chapter.id } }
    }
    func trimOffscreenChapters() {
        guard !closed, !restoring else { return }
        let removed = removeOffscreenChapters()
        guard !removed.isEmpty else { return }
        Task { await releaseChapters(removed) }
    }
    private func removeOffscreenChapters(prefer delta: Int? = nil) -> [ReaderState] {
        var removed: [ReaderState] = []
        while scrollChapters.count > 3 {
            guard let active = scrollChapters.firstIndex(where: { $0.chapter.id == chapterID }) else { break }
            let first = delta.map { $0 > 0 } ?? (active >= scrollChapters.count - 1 - active)
            let candidate = first ? scrollChapters.first! : scrollChapters.last!
            guard candidate.chapter.id != chapterID, !visibleChapterIDs.contains(candidate.chapter.id) else { break }
            removed.append(first ? scrollChapters.removeFirst() : scrollChapters.removeLast())
        }
        let kept = Set(scrollChapters.map(\.chapter.id))
        readyPages = readyPages.filter { kept.contains($0.chapterID) }; pageAspects = pageAspects.filter { kept.contains($0.key.chapterID) }
        for direction in [-1, 1] where errorChapters[direction] != adjacentChapter(direction)?.id { adjacentErrors[direction] = nil; errorChapters[direction] = nil }
        return removed
    }
    private func releaseChapters(_ removed: [ReaderState]) async {
        guard !closed else { return }
        // An in-flight adjacent preparation may have completed on the session actor
        // before its main-actor continuation inserts it into the visible window.
        let pending = adjacentLoading.compactMap { adjacentChapter($0)?.id }
        await session.retainChapters(Set(scrollChapters.map(\.chapter.id)).union(pending))
        for old in removed where !scrollChapters.contains(where: { $0.chapter.id == old.chapter.id }) { await app.images.leave(chapterID: old.chapter.id) }
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
