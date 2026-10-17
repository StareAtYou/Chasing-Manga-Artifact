import SwiftUI
import MangaCore
struct DownloadsView: View {
    var workID: WorkID? = nil
    @State private var associatedIDs = Set<SourceWorkID>()
    private var tasks: [DownloadTask] { workID == nil ? app.downloadList : app.downloadList.filter { associatedIDs.contains($0.chapter.id.sourceWorkID) } }
    private var preparations: [DownloadPreparationState] {
        app.downloadPreparations.values.filter { state in
            workID == nil || associatedIDs.contains(state.sourceWorkID)
        }.sorted { lhs, rhs in
            if lhs.isPreparing != rhs.isPreparing { return lhs.isPreparing }
            return lhs.sourceWorkID.key < rhs.sourceWorkID.key
        }
    }
    @Environment(AppContainer.self) private var app
    @State private var deleting: DownloadTask?
    var body: some View {
        VStack {
            ForEach(preparations) { preparation in preparationCard(preparation) }
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
        .task {
            if let workID { await app.perform { associatedIDs = Set(try await app.store.sourceWorks(for: workID).map(\.id)) } }
            while !Task.isCancelled { await app.perform { try await app.refresh() }; do { try await Task.sleep(for: .seconds(1)) } catch { break } } }
    }
    private func preparationCard(_ preparation: DownloadPreparationState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("下载准备 · \(preparation.workTitle ?? "已保存的漫画")").font(.headline)
            SourceBadge(name: app.sourceName(preparation.sourceWorkID.sourceID))
            if preparation.isPreparing && preparation.refreshingDirectory { Label("正在刷新完整目录…", systemImage: "arrow.clockwise") }
            else { Text("已处理 \(preparation.finished) / \(preparation.total) 章 · 已有 \(preparation.existing) 章在队列或已下载 · 跳过 \(preparation.skipped) 章受限内容").font(.caption).foregroundStyle(.secondary) }
            if let failure = preparation.failure { Text("准备失败：\(failure)").font(.caption).foregroundStyle(.red) }
            if preparation.isPreparing {
                HStack { ProgressView(); Button("取消准备") { app.cancelPreparation(sourceWorkIDs: [preparation.sourceWorkID]) }.disabled(preparation.cancelled) }
            } else if preparation.failure == nil {
                Text(preparation.cancelled ? "准备已取消；已加入队列的章节会继续下载。再次点击整部下载可补齐。" : "目录处理已结束，实际下载进度见下方各章节。").font(.caption).foregroundStyle(.secondary)
            }
            if !preparation.errors.isEmpty {
                DisclosureGroup("\(preparation.errors.count) 章未加入队列") {
                    ForEach(Array(preparation.errors.keys).sorted { $0.key < $1.key }, id: \.self) { id in
                        Text("\(app.chapterTitle(id))：\(preparation.errors[id] ?? "")").font(.caption)
                    }
                }
            }
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
    }
    private func action(_ work: @escaping () async throws -> Void) { Task { await app.perform { try await work(); try await app.refresh() } } }
    private func stateTitle(_ state: DownloadState) -> String { switch state { case .queued: "等待下载"; case .running: "下载中"; case .paused: "已暂停"; case .failed: "下载失败"; case .completed: "已下载"; case .cancelled: "已取消" } }
}
