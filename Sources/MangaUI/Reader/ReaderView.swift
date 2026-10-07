import SwiftUI
import Observation
import MangaCore
import MangaPlatform
public struct ReaderView: View {
    @State private var model: ReaderModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var readerFocused: Bool
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
            .focusable().focused($readerFocused).defaultFocus($readerFocused, true)
            .onChange(of: model.isReady) { _, ready in if ready { readerFocused = true } }
            .onKeyPress(.leftArrow) { model.stepPages(visualDelta: -1); return .handled }
            .onKeyPress(.rightArrow) { model.stepPages(visualDelta: 1); return .handled }
            #endif
    }

}
struct ComicPageView: View {
    let model: ReaderModel
    let page: PageResource
    let width: CGFloat
    var sizeResolved: (Double) -> Void = { _ in }
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
        .accessibilityIdentifier("comic-page-\(page.ordinal)")
        .accessibilityLabel("第 \(page.ordinal + 1) 页漫画")
        .task(id: retry) {
            do {
                let file: URL
                if let offline = model.offlineFile(for: page.id) { file = offline } else { file = try await model.app.images.file(for: page, sourceID: page.id.chapterID.sourceWorkID.sourceID) }
                let metadata = try await Task.detached { try ImageVerifier().verify(Data(contentsOf: file)) }.value
                let decoded = try await model.app.images.tiles(file: file, pageID: page.id, viewport: PixelRect(x: 0, y: 0, width: metadata.width, height: metadata.height), targetWidth: min(2048, max(1, Int(width * 2))))
                try Task.checkCancellation(); aspect = Double(metadata.height) / Double(metadata.width); sizeResolved(aspect); tiles = decoded; failure = nil
                await model.session.recordFailure(pageID: page.id, error: nil); model.pageReady(page.id); ready()
            } catch is CancellationError { } catch { failure = error.localizedDescription; await model.session.recordFailure(pageID: page.id, error: (error as? MangaError) ?? .invalidImage); model.pageReady(page.id); ready() }
        }
    }
}
