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
    var body: some View {
        GeometryReader { geometry in ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) { ForEach(state.pages) { page in
                    ComicPageView(model: model, page: page, width: min(1000, geometry.size.width) * scale, restoredFraction: model.scrollRequest?.pageID == page.id ? model.scrollRequest?.fraction ?? 0 : 0) {
                        if model.restoring, model.scrollRequest?.pageID == page.id { finishRestore(proxy) }
                    }.id(page.id).background(GeometryReader { local in Color.clear.preference(key: PageFrames.self, value: [page.id: local.frame(in: .named("reader"))]) })
                } }.frame(maxWidth: .infinity)
            }.coordinateSpace(name: "reader").accessibilityIdentifier("reader-scroll")
                .gesture(MagnifyGesture().onEnded { value in scale = min(3, max(1, scale * value.magnification)) })
                .onPreferenceChange(PageFrames.self) { frames in
                    guard !model.restoring, let visible = state.pages.first(where: { if let frame = frames[$0.id] { return frame.maxY > 1 && frame.minY < geometry.size.height }; return false }), let frame = frames[visible.id] else { return }
                    model.position(visible.id, fraction: min(1, max(0, -frame.minY / max(1, frame.height))), mode: .scroll)
                }
                .onAppear { model.requestScroll(pageID: state.progress.pageID, fraction: state.progress.fraction); beginRestore(proxy) }
                .onChange(of: model.scrollRequest?.token) { _, _ in beginRestore(proxy) }
                .onDisappear { restorationTask?.cancel() }
        } }
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
