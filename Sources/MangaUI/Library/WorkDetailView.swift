import SwiftUI
import MangaCore
struct WorkDetailView: View {
    let workID: WorkID
    @Environment(AppContainer.self) private var app
    @State private var work: Work?
    @State private var sources: [SourceWork] = []
    @State private var followed = Set<SourceWorkID>()
    @State private var candidates: [AssociationCandidate] = []
    @State private var selectedCandidate: AssociationCandidate?
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 24) {
            if let work {
                HStack(alignment: .top, spacing: 20) { CoverView(url: work.coverURL); VStack(alignment: .leading, spacing: 12) { Text(work.title).font(.title2.bold()); Text("选择来源后开始阅读").foregroundStyle(.secondary); Button(work.isOnShelf == false ? "加入书架" : "移出书架") { Task { if work.isOnShelf == false, let id = sources.first?.id { await app.addToShelf(workID, sourceWorkID: id) } else { await app.perform { try await app.store.setOnShelf(false, workID: workID); try await app.refresh() } }; await reload() } }.buttonStyle(.borderedProminent) } }
                Text("阅读来源").font(.headline)
                ForEach(sources) { source in VStack(alignment: .leading, spacing: 10) {
                    HStack { SourceBadge(name: app.sourceName(source.id.sourceID)); Spacer(); if let date = source.checkedAt { Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) } }
                    Text(source.title).font(.headline); if !source.latestChapter.isEmpty { Text(source.latestChapter).font(.subheadline).foregroundStyle(.secondary) }
                    HStack { Button("选择此来源") { app.path.append(app.navigation.selectSource(source.id)) }.buttonStyle(.borderedProminent)
                        Toggle("关注更新", isOn: Binding(get: { followed.contains(source.id) }, set: { value in Task { await app.perform { try await app.updates.setFollowed(value, sourceWorkID: source.id); if value { followed.insert(source.id) } else { followed.remove(source.id) } } } })).toggleStyle(.switch)
                        if sources.count > 1 { Button("解除关联") { Task { await app.perform { try await app.associations.unlink(source.id, from: workID); try await app.refresh() }; await reload() } } }
                    }
                    if !app.sourceList.contains(where: { $0.id == source.id.sourceID && $0.enabled }) { Label("此来源当前不可在线访问，已下载内容可离线阅读", systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary) }
                }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 14)) }
                if !candidates.isEmpty { Text("可能的其他来源").font(.headline); ForEach(candidates) { candidate in Button { selectedCandidate = candidate } label: { VStack(alignment: .leading) { Text(candidate.work.title); Text(candidate.reason).font(.caption).foregroundStyle(.secondary); SourceBadge(name: app.sourceName(candidate.id.sourceID)) } }.buttonStyle(.plain) } }
            } else { ProgressView() }
        }.padding(24).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity) }.navigationTitle(work?.title ?? "作品详情").task { await reload() }
        .confirmationDialog("确认将这个来源关联到当前作品？", isPresented: Binding(get: { selectedCandidate != nil }, set: { if !$0 { selectedCandidate = nil } })) { Button("确认关联") { if let selectedCandidate { Task { await app.perform { try await app.associations.confirmLink(selectedCandidate.id, to: workID); try await app.refresh() }; await reload() } }; selectedCandidate = nil }; Button("取消", role: .cancel) { selectedCandidate = nil } }
    }
    private func reload() async { await app.perform { work = try await app.store.work(id: workID); sources = try await app.store.sourceWorks(for: workID); followed = Set(try await app.updates.followedIDs()); candidates = sources.first.map { app.associations.candidates(for: $0, among: app.catalog.filter { other in !sources.contains { $0.id == other.id } }) } ?? [] } }
}
