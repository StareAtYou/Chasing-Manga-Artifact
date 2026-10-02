import SwiftUI
import MangaCore
struct DownloadsView: View {
    @Environment(AppContainer.self) private var app
    @State private var deleting: DownloadTask?
    var body: some View {
        VStack {
            if app.preparingBatch { HStack { ProgressView(); Text("准备章节：\(app.preparationFinished) / \(app.preparationTotal)"); Button("取消准备") { app.cancelPreparation() } }.padding() }
            if !app.preparationErrors.isEmpty { DisclosureGroup("\(app.preparationErrors.count) 章未加入队列") { ForEach(Array(app.preparationErrors.keys).sorted { $0.key < $1.key }, id: \.self) { id in Text("\(app.chapterTitle(id))：\(app.preparationErrors[id] ?? "")").font(.caption) } }.padding() }
            if app.downloadList.isEmpty { EmptyState(title: "还没有下载", icon: "arrow.down.circle", message: "在章节目录中下载，完成后可断网阅读。") }
            else { ScrollView { LazyVStack(spacing: 16) { ForEach(app.downloadList) { task in VStack(alignment: .leading, spacing: 10) { Text(app.catalog.first { $0.id == task.chapter.id.sourceWorkID }?.title ?? "已保存的漫画").font(.headline); HStack { Text(task.chapter.title).font(.subheadline); Spacer(); SourceBadge(name: app.sourceName(task.chapter.id.sourceWorkID.sourceID)) }; Text(stateTitle(task.state)).font(.caption).foregroundStyle(.secondary); ProgressView(value: Double(task.completedPages), total: Double(max(1, task.pages.count))); Text("\(task.completedPages) / \(task.pages.count) 页 · \(ByteCountFormatter.string(fromByteCount: Int64(task.bytes), countStyle: .file))").font(.caption); if let error = task.error { Text(error.localizedDescription).font(.caption).foregroundStyle(.red) }; HStack {
                if task.state == .completed { Button("离线阅读") { app.path.append(.reader(task.chapter.id)) } }
                else if [.running, .queued].contains(task.state) { Button("暂停") { action { try await app.downloads.pause(taskID: task.id) } } }
                else { Button("继续 / 重试") { action { try await app.downloads.retry(taskID: task.id) } } }
                if task.state != .completed && task.state != .cancelled { Button("取消") { action { try await app.downloads.cancel(taskID: task.id) } } }
                Button("删除下载", role: .destructive) { deleting = task }
            }.buttonStyle(.bordered) }.padding(18).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14)) } }.padding(20) } }
        }.navigationTitle("下载")
        .confirmationDialog("删除该章节的离线图片？书架与阅读进度会保留。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) { Button("删除离线图片", role: .destructive) { if let deleting { action { try await app.downloads.deleteDownloaded(chapterID: deleting.chapter.id) } }; deleting = nil }; Button("取消", role: .cancel) { deleting = nil } }
        .task { while !Task.isCancelled { await app.perform { try await app.refresh() }; do { try await Task.sleep(for: .seconds(1)) } catch { break } } }
    }
    private func action(_ work: @escaping () async throws -> Void) { Task { await app.perform { try await work(); try await app.refresh() } } }
    private func stateTitle(_ state: DownloadState) -> String { switch state { case .queued: "等待下载"; case .running: "下载中"; case .paused: "已暂停"; case .failed: "下载失败"; case .completed: "已下载"; case .cancelled: "已取消" } }
}
