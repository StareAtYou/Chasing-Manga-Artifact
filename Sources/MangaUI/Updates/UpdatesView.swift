import SwiftUI
import MangaCore
struct UpdatesView: View {
    @Environment(AppContainer.self) private var app
    @State private var checking = false
    var body: some View {
        List {
            if checking { ProgressView("正在检查关注来源…") }
            ForEach(app.updateStatuses.filter { $0.error != nil || $0.notificationError != nil }) { status in Section {
                Text((status.error ?? status.notificationError)?.localizedDescription ?? "").font(.subheadline).foregroundStyle(.secondary)
                Text(status.checkedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                Button("重试检查") { Task { _ = await app.updates.check(sourceWorkIDs: [status.sourceWorkID]); try? await app.refresh() } }.buttonStyle(.borderless)
            } header: { Text("\(title(status.sourceWorkID)) · \(app.sourceName(status.sourceWorkID.sourceID))") } }
            if app.updateList.allSatisfy({ $0.newChapters.isEmpty }) { EmptyState(title: "暂无未读新章节", icon: "sparkles", message: "加入书架后关注阅读来源。首次检查建立基线；读过的新章节会自动移出这里。") }
            ForEach(app.updateList.filter { !$0.newChapters.isEmpty }) { observation in Section {
                ForEach(observation.newChapters) { chapter in HStack {
                    Button { app.path.append(.reader(chapter.id)) } label: { Text(chapter.title).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                    Button("标为已读") { Task { await app.perform { try await app.updates.markRead(chapterID: chapter.id); try await app.refresh() } } }.font(.caption)
                }.buttonStyle(.borderless) }
                Text("检查于 \(observation.checkedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            } header: { HStack { Text(title(observation.sourceWorkID)); SourceBadge(name: app.sourceName(observation.sourceWorkID.sourceID)) } } }
        }.navigationTitle("更新").toolbar { Button { Task { checking = true; defer { checking = false }; await app.perform { let ids = try await app.updates.followedIDs(); _ = await app.updates.check(sourceWorkIDs: ids); try await app.refresh() } } } label: { Label("检查更新", systemImage: "arrow.clockwise") }.disabled(checking) }
        .task { try? await app.refresh() }
    }
    private func title(_ id: SourceWorkID) -> String { app.catalog.first { $0.id == id }?.title ?? "漫画" }
}
