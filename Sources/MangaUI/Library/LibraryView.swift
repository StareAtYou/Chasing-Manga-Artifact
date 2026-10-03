import SwiftUI
import MangaCore
struct LibraryView: View {
    @Environment(AppContainer.self) private var app
    @State private var filter = ShelfFilter.all
    @State private var removing: Work?
    private enum ShelfFilter: String, CaseIterable { case all = "全部", offline = "已离线", downloading = "下载中" }
    private var visible: [Work] {
        app.library.filter { work in
            let tasks = app.shelfDownloads(for: work.id)
            switch filter { case .all: return true; case .offline: return tasks.contains { $0.state == .completed }; case .downloading: return tasks.contains { [.queued, .running].contains($0.state) } || !app.preparationSourceWorkIDs.isDisjoint(with: app.workSourceIDs[work.id] ?? []) }
        }
    }
    @State private var showHistory = false
    @State private var showSettings = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("书架筛选", selection: $filter) { ForEach(ShelfFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 420)
                Spacer(minLength: 8)
            }.padding()
            if !app.downloadList.isEmpty || app.preparingBatch {
                Button { app.presentDownloads() } label: {
                    HStack { Label("书架下载", systemImage: "arrow.down.circle"); Spacer(); Text("\(app.downloadList.filter { $0.state == .completed }.count) 章已离线 · \(app.downloadList.filter { [.running, .queued].contains($0.state) }.count) 章下载中").font(.caption); Image(systemName: "chevron.right") }
                }.buttonStyle(.plain).padding(.horizontal).padding(.bottom)
            }
            Group {
            if app.library.isEmpty { ContentUnavailableView { Label("书架还空着", systemImage: "books.vertical") } description: { Text("浏览或搜索漫画，选择来源后加入书架。") } actions: { Button("去发现漫画") { app.section = .discovery }.buttonStyle(.borderedProminent) } }
            else if visible.isEmpty { EmptyState(title: "没有匹配的漫画", icon: "line.3.horizontal.decrease.circle", message: "切换到全部，或在作品目录中下载章节。") }
            else { ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .top)], spacing: 24) { ForEach(visible) { work in shelfCard(work) } }.padding(24) } }
        }
        }.navigationTitle("书架").toolbar {
            Button { app.presentDownloads() } label: { Label("管理下载", systemImage: "arrow.down.circle") }
            Button { showHistory = true } label: { Label("阅读历史", systemImage: "clock") }
            Button { showSettings = true } label: { Label("设置", systemImage: "gearshape") }
        }
        .confirmationDialog("移出书架并删除下载？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("移出并删除全部下载", role: .destructive) { if let work = removing { Task { await app.removeFromShelf(work.id) } }; removing = nil }
            Button("取消", role: .cancel) { removing = nil }
        } message: { Text("该作品所有关联来源的下载都会删除，阅读历史和进度会保留。") }
        .sheet(isPresented: $showHistory) { NavigationStack { List(app.history, id: \.sourceWorkID) { progress in Button { Task { showHistory = false; await app.resume(progress) } } label: {
            VStack(alignment: .leading, spacing: 6) { Text(app.catalog.first { $0.id == progress.sourceWorkID }?.title ?? "历史漫画").font(.headline); Text(app.chapterTitle(progress.chapterID)).font(.subheadline); HStack { SourceBadge(name: app.sourceName(progress.sourceWorkID.sourceID)); Text(progress.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) } }
        }.buttonStyle(.borderless).padding(.vertical, 6) }.overlay { if app.history.isEmpty { EmptyState(title: "暂无阅读历史", icon: "clock", message: "阅读过的章节会自动保存在这里。") } }.navigationTitle("阅读历史").toolbar { Button("完成") { showHistory = false } }.frame(minWidth: 320, minHeight: 400) } }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .task { await app.perform { try await app.refresh() }; await app.observeShelfDownloadStatus() }
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
        let tasks = app.shelfDownloads(for: work.id)
        if !tasks.isEmpty {
            Text("\(tasks.filter { $0.state == .completed }.count) 章已离线").font(.caption).foregroundStyle(.secondary)
            let active = tasks.filter { [.queued, .running].contains($0.state) }
            if !active.isEmpty { ProgressView(value: Double(active.reduce(0) { $0 + $1.completedPages }), total: Double(max(1, active.reduce(0) { $0 + $1.pages.count }))); Text("\(active.count) 章下载中").font(.caption).foregroundStyle(.secondary) }
            Button("管理下载") { app.presentDownloads(for: work.id) }.font(.caption).buttonStyle(.borderless)
        }
        Button("详情 / 更换来源") { app.path.append(.work(work.id)) }.font(.caption).buttonStyle(.borderless)
        }
            .contextMenu { Button("继续阅读") { Task { await app.open(work) } }; Button("作品详情 / 更换来源") { app.path.append(.work(work.id)) }; Button("移出书架", role: .destructive) { removing = work } }
    }
}
