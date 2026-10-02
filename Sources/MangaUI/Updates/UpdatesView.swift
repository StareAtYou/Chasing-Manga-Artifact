import SwiftUI
import MangaCore
struct UpdatesView: View {
    @Environment(AppContainer.self) private var app
    @State private var checking = false
    var body: some View {
        Group { if app.updateList.allSatisfy({ $0.newChapters.isEmpty }) { EmptyState(title: "暂无新章节", icon: "sparkles", message: "关注书架作品的阅读来源，更新会保存在这里。首次检查只建立基线。") }
            else { List { ForEach(app.updateList.filter { !$0.newChapters.isEmpty }) { observation in Section { ForEach(observation.newChapters) { chapter in Button { app.path.append(.reader(chapter.id)) } label: { Text(chapter.title) } } } header: { HStack { Text(app.catalog.first { $0.id == observation.sourceWorkID }?.title ?? "漫画"); SourceBadge(name: app.sourceName(observation.sourceWorkID.sourceID)) } } } } }
        }.navigationTitle("更新").toolbar { Button { Task { checking = true; defer { checking = false }; await app.perform { let ids = try await app.updates.followedIDs(); _ = await app.updates.check(sourceWorkIDs: ids); try await app.refresh() } } } label: { if checking { ProgressView() } else { Label("检查更新", systemImage: "arrow.clockwise") } }.disabled(checking) }
    }
}
