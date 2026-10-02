import SwiftUI
import MangaCore
struct ChapterListView: View {
    let sourceWorkID: SourceWorkID
    @Environment(AppContainer.self) private var app
    @State private var work: SourceWork?
    @State private var chapters: [Chapter] = []
    @State private var loading = false
    var body: some View {
        List { Section { HStack { SourceBadge(name: app.sourceName(sourceWorkID.sourceID)); Spacer(); Text("\(chapters.count) 章").foregroundStyle(.secondary) } }
            if loading { ProgressView("读取章节目录…") }
            ForEach(chapters) { chapter in HStack { Button { app.path.append(.reader(chapter.id)) } label: { HStack { Text(chapter.title); Spacer(); if chapter.access != .available { Image(systemName: "lock") } } }.buttonStyle(.plain)
                Button { Task { await app.perform { let pages = try await app.sources.pages(chapter: chapter); _ = try await app.downloads.enqueue(chapter: chapter, pages: pages); try await app.refresh() } } } label: { Label("下载 \(chapter.title)", systemImage: "arrow.down.circle") }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(chapter.access != .available)
            } }
            if !loading && chapters.isEmpty { EmptyState(title: "未取得章节", icon: "list.bullet", message: "请检查来源状态，或在源管理中打开网站完成验证。") }
        }.navigationTitle(work?.title ?? "章节").toolbar { Button { Task { await load(refresh: true) } } label: { Label("刷新目录", systemImage: "arrow.clockwise") } }.task { await load(refresh: false) }
    }
    private func load(refresh: Bool) async { loading = true; defer { loading = false }; await app.perform { work = try await app.store.sourceWork(id: sourceWorkID); chapters = try await app.store.chapters(for: sourceWorkID); if let work, refresh || chapters.isEmpty { let fetched = try await app.sources.chapters(work: work); try await app.store.save(sourceWork: work, chapters: fetched); chapters = try await app.store.chapters(for: sourceWorkID) } } }
}
