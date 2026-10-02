import SwiftUI
import MangaCore
struct PagedReader: View {
    let model: ReaderModel
    let state: ReaderState
    private var spreads: [[PageID]] {
        #if os(macOS)
        if state.preferences.mode == .doublePage { return PageLayout.spreads(pageIDs: state.pages.map(\.id), direction: state.preferences.direction) }
        #endif
        return state.pages.map { [$0.id] }
    }
    private var index: Int { spreads.firstIndex { $0.contains(state.progress.pageID) } ?? 0 }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 12) {
                ZoomablePage { HStack(spacing: 8) { ForEach(spreads[index], id: \.self) { id in if let page = state.pages.first(where: { $0.id == id }) { ComicPageView(model: model, page: page, width: max(1, (geometry.size.width - 32) / CGFloat(spreads[index].count)), ready: { model.restoring = false }) } } } }.id(index)
                HStack { Button { step(-1) } label: { Label("上一页", systemImage: state.preferences.direction == .rightToLeft ? "chevron.right" : "chevron.left") }.disabled(index == 0); Spacer(); Text("\(state.pages.firstIndex(where: { $0.id == state.progress.pageID }).map { $0 + 1 } ?? 1) / \(state.pages.count)").monospacedDigit(); Spacer(); Button { step(1) } label: { Label("下一页", systemImage: state.preferences.direction == .rightToLeft ? "chevron.left" : "chevron.right") }.disabled(index == spreads.count - 1) }.padding(.horizontal)
            }.padding(.bottom, 8)
                .gesture(DragGesture(minimumDistance: 60).onEnded { value in guard abs(value.translation.width) > abs(value.translation.height) else { return }; let forward = state.preferences.direction == .rightToLeft ? value.translation.width > 0 : value.translation.width < 0; step(forward ? 1 : -1) })
        }
    }
    private func step(_ delta: Int) { guard spreads.indices.contains(index + delta), let id = spreads[index + delta].min(by: { ($0.externalID) < ($1.externalID) }) else { return }; let logical = state.pages.first { spreads[index + delta].contains($0.id) }?.id ?? id; model.position(logical, fraction: 0, mode: state.preferences.mode) }
}
