import SwiftUI
import MangaCore
private struct PageFrames: PreferenceKey {
    static let defaultValue: [PageID: CGRect] = [:]
    static func reduce(value: inout [PageID: CGRect], nextValue: () -> [PageID: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
struct ScrollingReader: View {
    let model: ReaderModel
    let state: ReaderState
    @State private var scale: CGFloat = 1
    @State private var restorationTask: Task<Void, Never>?
    @State private var edgeTasks: [Int: Task<Void, Never>] = [:]
    @State private var lastScrollIntent = 0
    @State private var frames: [PageID: CGRect] = [:]
    var body: some View {
        GeometryReader { geometry in ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    boundary(-1)
                    ForEach(model.scrollChapters, id: \.chapter.id) { chapter in
                        Section {
                            ForEach(chapter.pages) { page in
                                ComicPageView(model: model, page: page, width: min(1000, geometry.size.width) * scale, restoredFraction: model.scrollRequest?.pageID == page.id ? model.scrollRequest?.fraction ?? 0 : 0) {
                                    if model.restoring, model.scrollRequest?.pageID == page.id { finishRestore(proxy) }
                                }.id(page.id).background(GeometryReader { local in Color.clear.preference(key: PageFrames.self, value: [page.id: local.frame(in: .named("reader"))]) })
                            }
                        } header: {
                            Text(chapter.chapter.title).font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 12)
                                .accessibilityIdentifier("reader-chapter-" + chapter.chapter.id.externalID)
                        }
                    }
                    boundary(1)
                }.frame(maxWidth: .infinity)
            }.coordinateSpace(name: "reader").accessibilityIdentifier("reader-scroll")
                #if os(macOS)
                .background(ScrollIntentObserver { delta in updatePosition(height: geometry.size.height, intent: delta) }.allowsHitTesting(false))
                #else
                .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
                    if abs(value.translation.height) > abs(value.translation.width) { updatePosition(height: geometry.size.height, intent: value.translation.height < 0 ? 1 : -1) }
                })
                #endif
                .gesture(MagnifyGesture().onEnded { value in scale = min(3, max(1, scale * value.magnification)) })
                .onPreferenceChange(PageFrames.self) { value in frames = value; updatePosition(height: geometry.size.height) }
                .onAppear { model.requestScroll(pageID: state.progress.pageID, fraction: state.progress.fraction); beginRestore(proxy) }
                .onChange(of: model.scrollRequest?.token) { _, _ in beginRestore(proxy) }
                .onChange(of: model.restoring) { _, restoring in if !restoring { updatePosition(height: geometry.size.height) } }
                .onDisappear { restorationTask?.cancel(); for task in edgeTasks.values { task.cancel() } }
        } }
    }
    private func boundary(_ delta: Int) -> some View {
        VStack(spacing: 6) {
            if model.adjacentLoading.contains(delta) { ProgressView(delta < 0 ? "加载上一话…" : "加载下一话…") }
            else if let error = model.adjacentErrors[delta] {
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Button(delta < 0 ? "重试上一话" : "重试下一话") { load(delta, retry: true) }
            } else if let chapter = model.adjacentChapter(delta) {
                Text((delta < 0 ? "向上继续阅读 · " : "向下继续阅读 · ") + chapter.title).font(.caption).foregroundStyle(.secondary)
            } else { Text(delta < 0 ? "已到第一话" : "已到最后一话").font(.caption).foregroundStyle(.secondary) }
        }.frame(minHeight: 44).padding(.horizontal)
            .accessibilityIdentifier(delta < 0 ? "reader-boundary-previous" : "reader-boundary-next")
    }
    private func updatePosition(height: CGFloat, intent: Int = 0) {
        guard !model.restoring else { return }
        let pages = model.scrollChapters.flatMap(\.pages)
        let ids = pages.map(\.id)
        let layout = frames.mapValues { ReadingPageFrame(minY: $0.minY, height: $0.height) }
        let fits = ids.first.flatMap { frames[$0] }.map { $0.minY >= -1 } == true && ids.last.flatMap { frames[$0] }.map { $0.maxY <= height + 1 } == true
        if intent != 0 { lastScrollIntent = intent }
        let focus = ContinuousPageLayout.visiblePage(ids, frames: layout, viewportHeight: height, intent: lastScrollIntent)
        guard let id = focus, let frame = frames[id] else { return }
        if let anchor = ids.first(where: { frames[$0].map { $0.maxY > 1 && $0.minY < height } == true }), let rect = frames[anchor] {
            model.viewportAnchor = ReadingProgress(chapterID: anchor.chapterID, pageID: anchor, fraction: max(0, -rect.minY / max(1, rect.height)))
        }
        model.position(id, fraction: min(1, max(0, -frame.minY / max(1, frame.height))), mode: .scroll)
        // Content shorter than the viewport requires user intent, preventing an automatic directory crawl.
        guard !fits || intent != 0 else { return }
        if let first = model.scrollChapters.first, first.chapter.id == model.chapterID,
           let page = first.pages.first, let rect = frames[page.id], rect.maxY > 0, rect.minY > -height * 0.5, !fits || intent < 0 { load(-1) }
        if let last = model.scrollChapters.last, last.chapter.id == model.chapterID,
           let page = last.pages.last, let rect = frames[page.id], rect.maxY > 0, rect.minY < height * 1.5, !fits || intent > 0 { load(1) }
    }
    private func load(_ delta: Int, retry: Bool = false) {
        guard edgeTasks[delta] == nil else { return }
        edgeTasks[delta] = Task { @MainActor in await model.loadAdjacent(delta, retry: retry); edgeTasks[delta] = nil }
    }
    private func beginRestore(_ proxy: ScrollViewProxy) {
        guard let request = model.scrollRequest else { return }
        restorationTask?.cancel(); proxy.scrollTo(request.pageID, anchor: .top)
        if model.readyPages.contains(request.pageID) { finishRestore(proxy) }
    }
    private func finishRestore(_ proxy: ScrollViewProxy) {
        guard let request = model.scrollRequest else { return }
        restorationTask?.cancel()
        restorationTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(100)); guard model.scrollRequest?.token == request.token else { return }; proxy.scrollTo("restore-" + request.pageID.key, anchor: .top); try await Task.sleep(for: .milliseconds(150)); guard model.scrollRequest?.token == request.token else { return }; model.restoring = false } catch { }
        }
    }
}
