import SwiftUI
import MangaCore
private struct PageFrames: PreferenceKey {
    static let defaultValue: [PageID: CGRect] = [:]
    static func reduce(value: inout [PageID: CGRect], nextValue: () -> [PageID: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
struct ScrollingReader: View {
    let model: ReaderModel
    let state: ReaderState
    @State private var initial: ReadingProgress?
    @State private var scale: CGFloat = 1
    var body: some View {
        GeometryReader { geometry in ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) { ForEach(state.pages) { page in
                    ComicPageView(model: model, page: page, width: min(1000, geometry.size.width) * scale, restoredFraction: initial?.pageID == page.id ? initial?.fraction ?? 0 : 0) {
                        if model.restoring, initial?.pageID == page.id { Task { @MainActor in try? await Task.sleep(for: .milliseconds(100)); proxy.scrollTo("restore-" + page.id.key, anchor: .top); try? await Task.sleep(for: .milliseconds(200)); model.restoring = false } }
                    }.id(page.id).background(GeometryReader { local in Color.clear.preference(key: PageFrames.self, value: [page.id: local.frame(in: .named("reader"))]) })
                } }.frame(maxWidth: .infinity)
            }.coordinateSpace(name: "reader")
                .gesture(MagnifyGesture().onEnded { value in scale = min(3, max(1, scale * value.magnification)) })
                .onPreferenceChange(PageFrames.self) { frames in
                    guard !model.restoring, let visible = state.pages.first(where: { if let frame = frames[$0.id] { return frame.maxY > 1 && frame.minY < geometry.size.height }; return false }), let frame = frames[visible.id] else { return }
                    model.position(visible.id, fraction: min(1, max(0, -frame.minY / max(1, frame.height))), mode: .scroll)
                }
                .onAppear { initial = state.progress; proxy.scrollTo(state.progress.pageID, anchor: .top) }
        } }
    }
}
