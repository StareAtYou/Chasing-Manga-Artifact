import SwiftUI
import MangaCore
struct DownloadsView: View {
    var workID: WorkID? = nil
    private var tasks: [DownloadTask] { workID.map { app.shelfDownloads(for: $0) } ?? app.downloadList }
    private var showsPreparation: Bool { workID == nil || !app.preparationSourceWorkIDs.isDisjoint(with: app.workSourceIDs[workID!] ?? []) }
    @Environment(AppContainer.self) private var app
    @State private var deleting: DownloadTask?
    var body: some View {
        VStack {
            if showsPreparation, let title = app.preparationWorkTitle {
                VStack(alignment: .leading, spacing: 8) {
                    Text("整部下载 · \(title)").font(.headline)
                    if app.preparingBatch && app.preparationTotal == 0 { Label("正在刷新完整目录…", systemImage: "arrow.clockwise") }
                    else { Text("已处理 \(app.preparationFinished) / \(app.preparationTotal) 章 · 已有 \(app.preparationExisting) 章在队列或已下载 · 跳过 \(app.preparationSkipped) 章受限内容").font(.caption).foregroundStyle(.secondary) }
                    if let failure = app.preparationFailure { Text("准备失败：\(failure)").font(.caption).foregroundStyle(.red) }
                    if app.preparingBatch { HStack { ProgressView(); Button("取消准备") { app.cancelPreparation() } } }
                    else if app.preparationFailure == nil { Text(app.preparationCancelled ? "准备已取消；已加入队列的章节会继续下载。再次点击整部下载可补齐。" : "目录处理已结束，实际下载进度见下方各章节。").font(.caption).foregroundStyle(.secondary) }
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            } else if showsPreparation && app.preparingBatch { HStack { ProgressView(); Text("准备章节：\(app.preparationFinished) / \(app.preparationTotal)"); Button("取消准备") { app.cancelPreparation() } }.padding() }
            if showsPreparation && !app.preparationErrors.isEmpty { DisclosureGroup("\(app.preparationErrors.count) 章未加入队列") { ForEach(Array(app.preparationErrors.keys).sorted { $0.key < $1.key }, id: \.self) { id in Text("\(app.chapterTitle(id))：\(app.preparationErrors[id] ?? "")").font(.caption) } }.padding() }
            if tasks.isEmpty { EmptyState(title: "还没有下载", icon: "arrow.down.circle", message: "在作品详情或章节目录中点击“下载整部漫画”，完成后可断网阅读。") }
            else { ScrollView { LazyVStack(spacing: 16) { ForEach(tasks) { task in VStack(alignment: .leading, spacing: 10) { Text(app.catalog.first { $0.id == task.chapter.id.sourceWorkID }?.title ?? "已保存的漫画").font(.headline); HStack { Text(task.chapter.title).font(.subheadline); Spacer(); SourceBadge(name: app.sourceName(task.chapter.id.sourceWorkID.sourceID)) }; Text(stateTitle(task.state)).font(.caption).foregroundStyle(.secondary); ProgressView(value: Double(task.completedPages), total: Double(max(1, task.pages.count))); Text("\(task.completedPages) / \(task.pages.count) 页 · \(ByteCountFormatter.string(fromByteCount: Int64(task.bytes), countStyle: .file))").font(.caption); if let error = task.error { Text(error.localizedDescription).font(.caption).foregroundStyle(.red) }; HStack {
                if task.state == .completed { Button("离线阅读") { app.showDownloads = false; app.path.append(.reader(task.chapter.id)) } }
                else if [.running, .queued].contains(task.state) { Button("暂停") { action { try await app.downloads.pause(taskID: task.id) } } }
                else { Button("继续 / 重试") { action { try await app.downloads.retry(taskID: task.id) } } }
                if task.state != .completed && task.state != .cancelled { Button("取消") { action { try await app.downloads.cancel(taskID: task.id) } } }
                Button("删除下载", role: .destructive) { deleting = task }
            }.buttonStyle(.bordered) }.padding(18).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14)) } }.padding(20) } }
        }.navigationTitle(workID.flatMap { id in app.library.first { $0.id == id }?.title }.map { $0 + " · 下载" } ?? "书架下载")
        .confirmationDialog("删除该章节的离线图片？书架与阅读进度会保留。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) { Button("删除离线图片", role: .destructive) { if let deleting { action { try await app.downloads.deleteDownloaded(chapterID: deleting.chapter.id) } }; deleting = nil }; Button("取消", role: .cancel) { deleting = nil } }
        .task { while !Task.isCancelled { await app.perform { try await app.refresh() }; do { try await Task.sleep(for: .seconds(1)) } catch { break } } }
    }
    private func action(_ work: @escaping () async throws -> Void) { Task { await app.perform { try await work(); try await app.refresh() } } }
    private func stateTitle(_ state: DownloadState) -> String { switch state { case .queued: "等待下载"; case .running: "下载中"; case .paused: "已暂停"; case .failed: "下载失败"; case .completed: "已下载"; case .cancelled: "已取消" } }
}
