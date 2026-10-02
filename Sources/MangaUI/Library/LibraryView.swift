import SwiftUI
import MangaCore
struct LibraryView: View {
    @Environment(AppContainer.self) private var app
    @State private var showHistory = false
    @State private var showSettings = false
    var body: some View {
        Group {
            if app.library.isEmpty { EmptyState(title: "书架还空着", icon: "books.vertical", message: "到发现页浏览或搜索漫画，选择来源后加入书架。") }
            else { ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .top)], spacing: 24) { ForEach(app.library) { work in Button { Task { await app.open(work) } } label: { VStack(alignment: .leading, spacing: 8) { CoverView(url: work.coverURL); Text(work.title).font(.headline).lineLimit(2); if let source = work.preferredSourceWorkID { SourceBadge(name: app.sourceName(source.sourceID)) }; if let progress = app.history.first(where: { $0.sourceWorkID == work.preferredSourceWorkID }) { Text("上次阅读 · \(progress.updatedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).accessibilityLabel("打开 \(work.title)") } }.padding(24) } }
        }.navigationTitle("书架").toolbar {
            Button { showHistory = true } label: { Label("阅读历史", systemImage: "clock") }
            Button { showSettings = true } label: { Label("设置", systemImage: "gearshape") }
        }.sheet(isPresented: $showHistory) { NavigationStack { List(app.history, id: \.sourceWorkID) { progress in Button { app.path.append(.reader(progress.chapterID)); showHistory = false } label: { VStack(alignment: .leading) { Text(app.catalog.first { $0.id == progress.sourceWorkID }?.title ?? "历史漫画"); Text(app.sourceName(progress.sourceWorkID.sourceID)).font(.caption).foregroundStyle(.secondary) } } }.navigationTitle("阅读历史").toolbar { Button("完成") { showHistory = false } } } }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .task { await app.perform { try await app.refresh() } }
    }
}
