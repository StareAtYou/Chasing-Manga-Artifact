import SwiftUI
import MangaCore
struct WorkDetailView: View {
    let workID: WorkID
    @Environment(AppContainer.self) private var app
    @State private var work: Work?
    @State private var sources: [SourceWork] = []
    @State private var followed = Set<SourceWorkID>()
    @State private var counts: [SourceWorkID: Int] = [:]
    @State private var candidates: [AssociationCandidate] = []
    @State private var selectedCandidate: AssociationCandidate?
    @State private var showAssociation = false
    @State private var showRemoval = false
    @State private var expandedSummary = false
    private var primary: SourceWork? { sources.first { $0.id == work?.preferredSourceWorkID } ?? sources.first }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 24) {
            if let work {
                HStack(alignment: .top, spacing: 20) {
                    CoverView(url: primary?.coverURL ?? work.coverURL, sourceWork: primary)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(work.title).font(.title2.bold()); if let primary, !primary.author.isEmpty { Text(primary.author).foregroundStyle(.secondary) }
                        Text("\(sources.count) 个关联来源 · 自行选择阅读").font(.subheadline).foregroundStyle(.secondary)
                        Button(work.isOnShelf == false ? "加入书架" : "移出书架") {
                            if work.isOnShelf == false, let id = primary?.id { Task { await app.addToShelf(workID, sourceWorkID: id); await reload() } }
                            else { showRemoval = true }
                        }.buttonStyle(.borderedProminent)
                        if work.isOnShelf != false { Button("管理下载") { app.presentDownloads(for: workID) }.buttonStyle(.bordered) }
                    }
                }
                if let summary = primary?.summary, !summary.isEmpty { VStack(alignment: .leading, spacing: 8) { Text(summary).lineLimit(expandedSummary ? nil : 5).foregroundStyle(.secondary); if summary.count > 120 { Button(expandedSummary ? "收起简介" : "展开简介") { expandedSummary.toggle() }.font(.caption) } } }
                HStack { Text("阅读来源").font(.headline); Spacer(); Button { showAssociation = true } label: { Label("关联其他来源", systemImage: "link.badge.plus") }.buttonStyle(.bordered) }
                ForEach(sources) { source in sourceCard(source) }
                if !candidates.isEmpty {
                    Text("已打开的其他来源候选").font(.headline)
                    ForEach(candidates) { candidate in Button { selectedCandidate = candidate } label: { VStack(alignment: .leading, spacing: 6) { Text(candidate.work.title); Text(candidate.reason).font(.caption).foregroundStyle(.secondary); SourceBadge(name: app.sourceName(candidate.id.sourceID)) } }.buttonStyle(.borderless) }
                }
            } else { ProgressView("读取作品资料…") }
        }.padding(24).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity) }.navigationTitle(work?.title ?? "作品详情")
            .task { await reload() }
            .confirmationDialog("移出书架并删除下载？", isPresented: $showRemoval, titleVisibility: .visible) {
                Button("移出并删除全部下载", role: .destructive) { Task { await app.removeFromShelf(workID); await reload() } }
                Button("取消", role: .cancel) { }
            } message: { Text("该作品所有关联来源的下载都会删除，阅读历史和进度会保留。") }
            .sheet(isPresented: $showAssociation, onDismiss: { Task { await reload() } }) { if let work { SourceAssociationSheet(work: work, existingIDs: Set(sources.map(\.id))) } }
            .confirmationDialog("确认将这个来源关联到当前作品？", isPresented: Binding(get: { selectedCandidate != nil }, set: { if !$0 { selectedCandidate = nil } }), titleVisibility: .visible) {
                Button("确认关联") { if let selectedCandidate { Task { await app.linkResult(selectedCandidate.work, to: workID); await reload() } }; selectedCandidate = nil }
                Button("取消", role: .cancel) { selectedCandidate = nil }
            }
    }
    private func sourceCard(_ source: SourceWork) -> some View {
        let progress = app.history.first { $0.sourceWorkID == source.id }
        let online = app.sourceList.contains { $0.id == source.id.sourceID && $0.enabled }
        return VStack(alignment: .leading, spacing: 12) {
            HStack { SourceBadge(name: app.sourceName(source.id.sourceID)); if source.id == work?.preferredSourceWorkID { Text("上次选择").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text("\(counts[source.id] ?? 0) 章").font(.caption).foregroundStyle(.secondary) }
            Text(source.title).font(.headline)
            if !source.latestChapter.isEmpty { Text("最新：\(source.latestChapter)").font(.subheadline).foregroundStyle(.secondary) }
            if let date = source.checkedAt { Text("检查于 \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("选择此来源") { Task { await app.chooseSource(source.id, for: workID) } }.buttonStyle(.borderedProminent)
                if let progress { Button("继续阅读") { Task { await app.resume(progress) } }.buttonStyle(.bordered) }
                Spacer(minLength: 0)
            }
            Button {
                app.startWholeDownload(source.id); app.presentDownloads(for: workID)
            } label: { Label("下载整部漫画", systemImage: "arrow.down.circle") }
                .buttonStyle(.bordered).disabled(!online || app.preparingBatch)
                .accessibilityIdentifier("download-whole-work")
            Toggle("关注这个来源的更新", isOn: Binding(get: { followed.contains(source.id) }, set: { value in Task { await app.perform { try await app.updates.setFollowed(value, sourceWorkID: source.id); if value { followed.insert(source.id) } else { followed.remove(source.id) } } } })).toggleStyle(.switch)
            if sources.count > 1 { Button("解除关联") { Task { await app.perform { try await app.associations.unlink(source.id, from: workID); try await app.refresh() }; await reload() } }.font(.caption) }
            if !online { Label("来源已停用或删除，已下载章节仍可离线阅读", systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary) }
        }.padding(18).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
    private func reload() async {
        await app.perform {
            work = try await app.store.work(id: workID); sources = try await app.store.sourceWorks(for: workID); followed = Set(try await app.updates.followedIDs())
            for source in sources { counts[source.id] = try await app.store.chapters(for: source.id).count }
            candidates = sources.first.map { app.associations.candidates(for: $0, among: app.catalog.filter { other in !sources.contains { $0.id == other.id } }) } ?? []
        }
    }
}
