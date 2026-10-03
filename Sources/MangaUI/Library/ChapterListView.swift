import SwiftUI
import MangaCore
struct ChapterListView: View {
    let sourceWorkID: SourceWorkID
    @Environment(AppContainer.self) private var app
    @State private var work: SourceWork?
    @State private var chapters: [Chapter] = []
    @State private var loading = false
    @State private var query = ""
    @State private var newestFirst = false
    @State private var selecting = false
    @State private var selection = Set<ChapterID>()
    @State private var resumeCandidates: [ChapterID] = []
    private var visible: [Chapter] { let found = chapters.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }; return newestFirst ? Array(found.reversed()) : found }
    var body: some View {
        ScrollView { LazyVStack(alignment: .leading, spacing: 14) {
            HStack { SourceBadge(name: app.sourceName(sourceWorkID.sourceID)); Spacer(); Text("\(chapters.count) 章").foregroundStyle(.secondary) }
            if let progress = app.history.first(where: { $0.sourceWorkID == sourceWorkID }) { Button("继续阅读：\(app.chapterTitle(progress.chapterID))") { Task { await app.resume(progress) } }.buttonStyle(.borderedProminent) }
            Button {
                app.startWholeDownload(sourceWorkID); app.section = .downloads
            } label: { Label("下载整部漫画", systemImage: "arrow.down.circle") }
                .buttonStyle(.bordered).disabled(loading || work == nil || app.preparingBatch || !app.sourceList.contains { $0.id == sourceWorkID.sourceID && $0.enabled })
                .accessibilityIdentifier("download-whole-work")
            HStack { TextField("筛选章节名称", text: $query).textFieldStyle(.roundedBorder); Toggle("最新在前", isOn: $newestFirst).toggleStyle(.button) }
            if selecting { HStack { Button("选择当前列表") { selection.formUnion(visible.filter { $0.access == .available }.map(\.id)) }; Button("清空") { selection.removeAll() }; Spacer(); Button("下载所选 \(selection.count) 章") { app.startBatch(chapters.filter { selection.contains($0.id) }); selecting = false; selection.removeAll() }.disabled(selection.isEmpty || app.preparingBatch) }.buttonStyle(.bordered) }
            if app.preparingBatch { HStack { ProgressView(); Text("加入下载队列：\(app.preparationFinished) / \(app.preparationTotal)"); Button("取消准备") { app.cancelPreparation() } }.font(.caption) }
            if !resumeCandidates.isEmpty { Text("其他来源的续读候选 · 请自行确认").font(.headline); ForEach(chapters.filter { resumeCandidates.contains($0.id) }) { chapter in Button(chapter.title) { app.path.append(.reader(chapter.id)) }.buttonStyle(.borderless) } }
            if loading { ProgressView("读取章节目录…") }
            ForEach(visible) { chapter in
                HStack(spacing: 12) {
                    if selecting { Toggle("选择 \(chapter.title)", isOn: Binding(get: { selection.contains(chapter.id) }, set: { if $0 { selection.insert(chapter.id) } else { selection.remove(chapter.id) } })).labelsHidden().disabled(chapter.access != .available) }
                    Button { app.path.append(.reader(chapter.id)) } label: { VStack(alignment: .leading, spacing: 5) { HStack { Text(chapter.title); Spacer(); if chapter.access != .available { Image(systemName: "lock") } }; HStack { if app.history.contains(where: { $0.chapterID == chapter.id }) { Text("上次阅读").foregroundStyle(.teal) }; if app.downloadList.contains(where: { $0.chapter.id == chapter.id && $0.state == .completed }) { Label("可离线阅读", systemImage: "checkmark.circle").foregroundStyle(.secondary) } }.font(.caption) }.contentShape(Rectangle()) }.buttonStyle(.borderless).accessibilityLabel("阅读 \(chapter.title)").accessibilityIdentifier("chapter-\(chapter.ordinal)")
                    if app.preparingChapters.contains(chapter.id) { ProgressView().controlSize(.small) }
                    else { Button { Task { await app.perform { try await app.queueDownload(chapter) } } } label: { Label("下载 \(chapter.title)", systemImage: "arrow.down.circle") }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(chapter.access != .available) }
                }.padding(.vertical, 6)
                Divider()
            }
            if !loading && chapters.isEmpty { EmptyState(title: "未取得章节", icon: "list.bullet", message: "请检查来源状态，或在源管理中打开网站完成验证。") }
            if !chapters.isEmpty && visible.isEmpty { Text("没有匹配的章节").foregroundStyle(.secondary) }
        }.padding(20) }.navigationTitle(work?.title ?? "章节").toolbar {
            Button(selecting ? "完成选择" : "批量下载") { selecting.toggle() }.disabled(chapters.isEmpty)
            Button { Task { await load(refresh: true) } } label: { Label("刷新目录", systemImage: "arrow.clockwise") }.disabled(loading)
        }.task { await load(refresh: false) }
    }
    private func load(refresh: Bool) async {
        loading = true; defer { loading = false }
        await app.perform {
            work = try await app.store.sourceWork(id: sourceWorkID); chapters = try await app.store.chapters(for: sourceWorkID)
            if let work, refresh || chapters.isEmpty { let fetched = try await app.sources.loadWork(url: work.url, sourceID: sourceWorkID.sourceID); try await app.store.save(sourceWork: fetched.work, chapters: fetched.chapters); self.work = fetched.work; chapters = try await app.store.chapters(for: sourceWorkID) }
            resumeCandidates = []
            if let workID = try await app.store.workID(for: sourceWorkID) { for other in try await app.store.sourceWorks(for: workID) where other.id != sourceWorkID { if let progress = try await app.store.progress(for: other.id) { let old = try await app.store.chapters(for: other.id); resumeCandidates += ResumeMatcher.candidates(progress: progress, from: old, to: chapters) } } }
            try await app.refresh()
        }
    }
}
