import SwiftUI
import MangaCore
struct LibraryView: View {
    @Environment(AppContainer.self) private var app
    @State private var showHistory = false
    @State private var showSettings = false
    var body: some View {
        Group {
            if app.library.isEmpty { ContentUnavailableView { Label("书架还空着", systemImage: "books.vertical") } description: { Text("浏览或搜索漫画，选择来源后加入书架。") } actions: { Button("去发现漫画") { app.section = .discovery }.buttonStyle(.borderedProminent) } }
            else { ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .top)], spacing: 24) { ForEach(app.library) { work in shelfCard(work) } }.padding(24) } }
        }.navigationTitle("书架").toolbar {
            Button { showHistory = true } label: { Label("阅读历史", systemImage: "clock") }
            Button { showSettings = true } label: { Label("设置", systemImage: "gearshape") }
        }
        .sheet(isPresented: $showHistory) { NavigationStack { List(app.history, id: \.sourceWorkID) { progress in Button { Task { showHistory = false; await app.resume(progress) } } label: {
            VStack(alignment: .leading, spacing: 6) { Text(app.catalog.first { $0.id == progress.sourceWorkID }?.title ?? "历史漫画").font(.headline); Text(app.chapterTitle(progress.chapterID)).font(.subheadline); HStack { SourceBadge(name: app.sourceName(progress.sourceWorkID.sourceID)); Text(progress.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) } }
        }.buttonStyle(.borderless).padding(.vertical, 6) }.overlay { if app.history.isEmpty { EmptyState(title: "暂无阅读历史", icon: "clock", message: "阅读过的章节会自动保存在这里。") } }.navigationTitle("阅读历史").toolbar { Button("完成") { showHistory = false } }.frame(minWidth: 320, minHeight: 400) } }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .task { await app.perform { try await app.refresh() } }
    }
    private func shelfCard(_ work: Work) -> some View {
        let source = app.catalog.first { $0.id == work.preferredSourceWorkID }
        let progress = app.history.first { $0.sourceWorkID == work.preferredSourceWorkID }
        return VStack(alignment: .leading, spacing: 10) {
        Button { Task { await app.open(work) } } label: {
            VStack(alignment: .leading, spacing: 10) {
                CoverView(url: source?.coverURL ?? work.coverURL, sourceWork: source, width: 120, height: 168)
                    .overlay(alignment: .topTrailing) { let count = app.unreadCount(for: work.id); if count > 0 { Text("\(count) 新章").font(.caption.bold()).padding(6).background(.teal, in: Capsule()).foregroundStyle(.white).offset(x: 8, y: -5) } }
                Text(work.title).font(.headline).lineLimit(2)
                if let source { SourceBadge(name: app.sourceName(source.id.sourceID)) }
                if let progress { Text(app.chapterTitle(progress.chapterID)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).accessibilityLabel("打开 \(work.title)")
        Button("详情 / 更换来源") { app.path.append(.work(work.id)) }.font(.caption).buttonStyle(.borderless)
        }
            .contextMenu { Button("继续阅读") { Task { await app.open(work) } }; Button("作品详情 / 更换来源") { app.path.append(.work(work.id)) }; Button("移出书架", role: .destructive) { Task { await app.removeFromShelf(work.id) } } }
    }
}
