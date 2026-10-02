import SwiftUI
import MangaCore
struct DownloadsView: View {
    @Environment(AppContainer.self) private var app
    var body: some View {
        Group { if app.downloadList.isEmpty { EmptyState(title: "还没有下载", icon: "arrow.down.circle", message: "在章节目录中下载，完成后可断网阅读。") }
            else { List(app.downloadList) { task in VStack(alignment: .leading, spacing: 10) { HStack { Text(task.chapter.title).font(.headline); Spacer(); SourceBadge(name: app.sourceName(task.chapter.id.sourceWorkID.sourceID)) }; Text(stateTitle(task.state)).font(.caption).foregroundStyle(.secondary); ProgressView(value: Double(task.completedPages), total: Double(max(1, task.pages.count))); Text("\(task.completedPages) / \(task.pages.count) 页 · \(ByteCountFormatter.string(fromByteCount: Int64(task.bytes), countStyle: .file))").font(.caption); if let error = task.error { Text(error.localizedDescription).font(.caption).foregroundStyle(.red) }; HStack {
                if task.state == .completed { Button("离线阅读") { app.path.append(.reader(task.chapter.id)) } }
                else if [.running, .queued].contains(task.state) { Button("暂停") { action { try await app.downloads.pause(taskID: task.id) } } }
                else { Button("继续 / 重试") { action { try await app.downloads.retry(taskID: task.id) } } }
                if task.state != .completed && task.state != .cancelled { Button("取消") { action { try await app.downloads.cancel(taskID: task.id) } } }
                Button("删除下载", role: .destructive) { action { try await app.downloads.deleteDownloaded(chapterID: task.chapter.id) } }
            }.buttonStyle(.bordered) }.padding(.vertical, 8) } }
        }.navigationTitle("下载").task { while !Task.isCancelled { await app.perform { try await app.refresh() }; do { try await Task.sleep(for: .seconds(1)) } catch { break } } }
    }
    private func action(_ work: @escaping () async throws -> Void) { Task { await app.perform { try await work(); try await app.refresh() } } }
    private func stateTitle(_ state: DownloadState) -> String { switch state { case .queued: "等待下载"; case .running: "下载中"; case .paused: "已暂停"; case .failed: "下载失败"; case .completed: "已下载"; case .cancelled: "已取消" } }
}
