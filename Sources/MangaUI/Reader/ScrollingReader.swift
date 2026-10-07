import SwiftUI
import MangaCore

struct ScrollingReader: View {
    let model: ReaderModel
    let state: ReaderState
    @State private var scale: CGFloat = 1
    @State private var viewport = ReadingViewport(offset: 0, height: 0, intent: 0)
    @State private var viewportLayout = ReadingScrollLayout(rows: [])
    @State private var lastInteraction: UInt64 = 0
    @State private var edgeTasks: [Int: Task<Void, Never>] = [:]
    private let headerHeight = 44.0
    private let boundaryHeight = 64.0
    private let spacing = 8.0

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, min(1000, viewport.width > 0 ? viewport.width : geometry.size.width) * scale)
            let layout = rowLayout(width: width)
            StableReadingScrollView(layout: layout, width: geometry.size.width, destination: destination,
                                    onScroll: { updatePosition($0, layout: layout) },
                                    content: content(width: width, layout: layout))
                .simultaneousGesture(MagnifyGesture().onEnded { value in scale = min(3, max(1, scale * value.magnification)) })
                .onAppear { model.requestScroll(pageID: state.progress.pageID, fraction: state.progress.fraction) }
                .onDisappear { for task in edgeTasks.values { task.cancel() } }
        }
    }
    private var destination: ReadingScrollDestination? {
        guard let request = model.scrollRequest else { return nil }
        return ReadingScrollDestination(token: request.token, rowID: request.pageID.key, fraction: request.fraction, ready: model.readyPages.contains(request.pageID))
    }
    private func rowLayout(width: CGFloat) -> ReadingScrollLayout {
        var rows = [ReadingScrollRow(id: "boundary-previous", height: boundaryHeight, anchors: false)]
        for chapter in model.scrollChapters {
            rows.append(ReadingScrollRow(id: "header-" + chapter.chapter.id.key, height: headerHeight))
            for page in chapter.pages { rows.append(ReadingScrollRow(id: page.id.key, height: width * model.aspect(for: page.id) + spacing)) }
        }
        rows.append(ReadingScrollRow(id: "boundary-next", height: boundaryHeight, anchors: false))
        return ReadingScrollLayout(rows: rows)
    }
    private func content(width: CGFloat, layout: ReadingScrollLayout) -> some View {
        let materialized = layout.materializedRows(from: viewportLayout, offset: viewport.offset, viewportHeight: max(800, viewport.height), margin: max(800, viewport.height))
        return VStack(spacing: 0) {
            boundary(-1)
            ForEach(model.scrollChapters, id: \.chapter.id) { chapter in
                Text(chapter.chapter.title).font(.subheadline).foregroundStyle(.secondary)
                    .frame(height: headerHeight).frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore).accessibilityLabel(chapter.chapter.title).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("reader-chapter-" + chapter.chapter.id.externalID)
                ForEach(chapter.pages) { page in
                    let height = width * model.aspect(for: page.id)
                    // Keep exact lightweight geometry for every page; decode only around the viewport.
                    // Unloaded/evicted views cannot make the stack estimate a different chapter height.
                    Group {
                        if materialized.contains(page.id.key) {
                            ComicPageView(model: model, page: page, width: width,
                                          sizeResolved: { model.pageAspect($0, for: page.id) })
                        } else { Color.clear }
                    }.frame(width: width, height: height, alignment: .top).clipped()
                        .padding(.bottom, spacing).frame(maxWidth: .infinity)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("第 \(page.ordinal + 1) 页漫画")
                        .accessibilityIdentifier("comic-page-\(page.ordinal)")
                }
            }
            boundary(1)
        }
    }
    private func boundary(_ delta: Int) -> some View {
        VStack(spacing: 4) {
            if model.adjacentLoading.contains(delta) { ProgressView(delta < 0 ? "加载上一话…" : "加载下一话…") }
            else if let error = model.adjacentErrors[delta] {
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button(delta < 0 ? "重试上一话" : "重试下一话") { load(delta, retry: true) }
            } else if let chapter = model.adjacentChapter(delta) {
                Text((delta < 0 ? "向上继续阅读 · " : "向下继续阅读 · ") + chapter.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else { Text(delta < 0 ? "已到第一话" : "已到最后一话").font(.caption).foregroundStyle(.secondary) }
        }.padding(.horizontal).frame(height: boundaryHeight).frame(maxWidth: .infinity)
            .accessibilityIdentifier(delta < 0 ? "reader-boundary-previous" : "reader-boundary-next")
    }
    private func updatePosition(_ value: ReadingViewport, layout: ReadingScrollLayout) {
        let userInteracted = value.interaction != lastInteraction
        lastInteraction = value.interaction
        if viewport != value { viewport = value }
        if viewportLayout != layout { viewportLayout = layout }
        model.visibleChapterIDs = Set(model.scrollChapters.filter { chapter in
            let keys = ["header-" + chapter.chapter.id.key] + chapter.pages.map { $0.id.key }
            return keys.contains { key in layout.frames[key].map { $0.maxY > value.offset && $0.minY < value.offset + value.height } == true }
        }.map(\.chapter.id))
        if model.restoring {
            if let request = model.scrollRequest, model.readyPages.contains(request.pageID) { model.restoring = false }
            else { return }
        }
        let pages = model.scrollChapters.flatMap(\.pages); let ids = pages.map(\.id)
        let frames = Dictionary(uniqueKeysWithValues: ids.compactMap { id -> (PageID, ReadingPageFrame)? in
            guard let row = layout.frames[id.key] else { return nil }
            return (id, ReadingPageFrame(minY: row.minY - value.offset, height: row.height - spacing))
        })
        let fits = ids.first.flatMap { frames[$0] }.map { $0.minY >= -1 } == true && ids.last.flatMap { frames[$0] }.map { $0.maxY <= value.height + 1 } == true
        guard let id = ContinuousPageLayout.visiblePage(ids, frames: frames, viewportHeight: value.height, intent: value.intent), let frame = frames[id] else { return }
        model.position(id, fraction: min(1, max(0, -frame.minY / max(1, frame.height))), mode: .scroll)
        model.trimOffscreenChapters()
        guard !fits || (userInteracted && value.intent != 0) else { return }
        if let first = model.scrollChapters.first, first.chapter.id == model.chapterID,
           let page = first.pages.first, let rect = frames[page.id], rect.maxY > 0, rect.minY > -value.height * 0.5, !fits || value.intent < 0 { load(-1) }
        if let last = model.scrollChapters.last, last.chapter.id == model.chapterID,
           let page = last.pages.last, let rect = frames[page.id], rect.maxY > 0, rect.minY < value.height * 1.5, !fits || value.intent > 0 { load(1) }
    }
    private func load(_ delta: Int, retry: Bool = false) {
        guard edgeTasks[delta] == nil else { return }
        edgeTasks[delta] = Task { @MainActor in await model.loadAdjacent(delta, retry: retry); edgeTasks[delta] = nil }
    }
}
