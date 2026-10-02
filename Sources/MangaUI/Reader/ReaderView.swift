import SwiftUI
import Observation
import MangaCore
import MangaPlatform
@MainActor @Observable final class ReaderModel {
    let app: AppContainer
    let chapterID: ChapterID
    let session: ReadingSession
    var state: ReaderState?
    var error: String?
    var directory: [Chapter] = []
    var restoring = true
    init(app: AppContainer, chapterID: ChapterID) { self.app = app; self.chapterID = chapterID; session = ReadingSession(store: app.store, sources: app.sources, downloads: app.downloads) }
    func load() async {
        do {
            guard let chapter = try await app.store.chapter(id: chapterID) else { throw MangaError.chapterUnavailable }
            let workID = try await app.store.workID(for: chapterID.sourceWorkID)
            let preferences: ReaderPreferences
            if let workID { preferences = try await app.store.preferences(for: workID) } else { preferences = ReaderPreferences() }
            state = try await session.open(chapter: chapter, preferences: preferences)
            directory = try await app.store.chapters(for: chapterID.sourceWorkID); error = nil
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
    func position(_ id: PageID, fraction: Double, mode: ReadingMode) {
        guard !restoring, state?.preferences.mode == mode else { return }
        state?.progress = ReadingProgress(chapterID: chapterID, pageID: id, fraction: fraction)
        Task { await app.perform { try await session.recordPosition(pageID: id, fraction: fraction) }; if let state, let index = state.pages.firstIndex(where: { $0.id == id }), state.offlineFiles.isEmpty { await app.images.prefetch(Array(state.pages.dropFirst(index + 1).prefix(3)), sourceID: state.sourceID) } }
    }
    func mode(_ value: ReadingMode) async { restoring = true; await app.perform { try await session.changeMode(value); state = await session.state } }
    func direction(_ value: ReadingDirection) async { await app.perform { try await session.changeDirection(value); state = await session.state } }
    func background(_ value: AppTheme) async { await app.perform { try await session.changeBackground(value); state = await session.state } }
    func close() async { await app.perform { try await session.close(); try await app.refresh() }; await app.images.leave(chapterID: chapterID) }
    func navigate(_ delta: Int) { guard let index = directory.firstIndex(where: { $0.id == chapterID }), directory.indices.contains(index + delta) else { return }; if !app.path.isEmpty { app.path.removeLast() }; app.path.append(.reader(directory[index + delta].id)) }
}
public struct ReaderView: View {
    @State private var model: ReaderModel
    @Environment(\.scenePhase) private var scenePhase
    public init(container: AppContainer, chapterID: ChapterID) { _model = State(initialValue: ReaderModel(app: container, chapterID: chapterID)) }
    public var body: some View {
        Group {
            if let state = model.state {
                Group { if state.preferences.mode == .scroll { ScrollingReader(model: model, state: state) } else { PagedReader(model: model, state: state) } }
                    .id(state.preferences.mode).background(state.preferences.background == .dark ? Color.black : state.preferences.background == .light ? Color.white : Color.primary.opacity(0.05))
            } else if let error = model.error { ContentUnavailableView { Label("无法打开章节", systemImage: "exclamationmark.triangle") } description: { Text(error) } actions: { Button("重试") { Task { await model.load() } } } }
            else { ProgressView("读取章节…") }
        }.navigationTitle(model.state?.chapter.title ?? "阅读").toolbar { ReaderToolbar(model: model) }
            .task { await model.load() }.onDisappear { Task { await model.close() } }
            .onChange(of: scenePhase) { _, value in if value != .active, let state = model.state { Task { try? await model.app.store.save(progress: state.progress) } } }
            #if os(macOS)
            .focusable().onKeyPress(.leftArrow) { pageStep(model.state?.preferences.direction == .rightToLeft ? 1 : -1); return .handled }
            .onKeyPress(.rightArrow) { pageStep(model.state?.preferences.direction == .rightToLeft ? -1 : 1); return .handled }
            #endif
    }
    private func pageStep(_ delta: Int) { guard let state = model.state, let index = state.pages.firstIndex(where: { $0.id == state.progress.pageID }), state.pages.indices.contains(index + delta) else { return }; model.position(state.pages[index + delta].id, fraction: 0, mode: state.preferences.mode) }
}
struct ComicPageView: View {
    let model: ReaderModel
    let page: PageResource
    let width: CGFloat
    var restoredFraction: Double = 0
    var ready: () -> Void = { }
    @State private var tiles: [ImageTile] = []
    @State private var aspect: Double = 1.4
    @State private var failure: String?
    @State private var retry = 0
    var body: some View {
        Group {
            if let failure { VStack(spacing: 12) { Image(systemName: "photo.badge.exclamationmark"); Text("第 \(page.ordinal + 1) 页加载失败"); Text(failure).font(.caption); Button("重试此页") { retry += 1 } }.frame(width: width, height: max(240, width * aspect)) }
            else if tiles.isEmpty { ProgressView("第 \(page.ordinal + 1) 页").frame(width: width, height: max(240, width * aspect)) }
            else { VStack(spacing: 0) { ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in Image(decorative: tile.image, scale: 1).resizable().frame(width: width, height: width * Double(tile.frame.height) / Double(tile.frame.width)) } } }
        }
        .overlay(alignment: .top) { Color.clear.frame(height: 1).offset(y: width * aspect * restoredFraction).id("restore-" + page.id.key) }
        .task(id: retry) {
            do {
                let file: URL
                if let offline = model.state?.offlineFiles[page.id] { file = offline } else { file = try await model.app.images.file(for: page, sourceID: page.id.chapterID.sourceWorkID.sourceID) }
                let metadata = try await Task.detached { try ImageVerifier().verify(Data(contentsOf: file)) }.value
                let decoded = try await model.app.images.tiles(file: file, pageID: page.id, viewport: PixelRect(x: 0, y: 0, width: metadata.width, height: metadata.height), targetWidth: min(2048, max(1, Int(width * 2))))
                try Task.checkCancellation(); aspect = Double(metadata.height) / Double(metadata.width); tiles = decoded; failure = nil
                await model.session.recordFailure(pageID: page.id, error: nil); ready()
            } catch is CancellationError { } catch { failure = error.localizedDescription; await model.session.recordFailure(pageID: page.id, error: (error as? MangaError) ?? .invalidImage); ready() }
        }
    }
}
