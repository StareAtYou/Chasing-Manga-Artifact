import SwiftUI
import MangaCore
struct SourceColumnView: View {
    let sourceID: SourceID
    @Environment(AppContainer.self) private var app
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let snapshot = app.recommendationSnapshot(for: sourceID) {
                    CatalogFreshness(snapshot: snapshot)
                    Text("漫画分类").font(.title2.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 12) {
                        ForEach(snapshot.channels.filter { $0.kind == .genre }) { channel in
                            NavigationLink(value: Route.catalogChannel(sourceID, channel.id)) { Text(channel.title).font(.headline).frame(maxWidth: .infinity).padding(14).background(.teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain)
                        }
                    }
                    ForEach(snapshot.channels.filter { $0.kind != .genre }) { channel in
                        NavigationLink(value: Route.catalogChannel(sourceID, channel.id)) { HStack { Label(channel.title, systemImage: channel.kind == .popular ? "chart.bar" : "square.grid.2x2"); Spacer(); Image(systemName: "chevron.right") }.padding().background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain)
                    }
                    if snapshot.channels.allSatisfy({ $0.kind != .genre }) { Text("此来源没有提供可解析的分类，仍可通过来源浏览寻找漫画。") .font(.subheadline).foregroundStyle(.secondary) }
                    if let section = snapshot.sections.first { Text(section.channel.title).font(.title2.bold()); CatalogChannelContents(sourceID: sourceID, channel: section.channel).id(section.channel.id) }
                } else { EmptyState(title: "来源当前不可用", icon: "network", message: "返回推荐刷新，或在漫画源管理中检查来源状态。") }
            }.padding(24).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle(app.sourceName(sourceID))
    }
}
struct GenreColumnView: View {
    let genre: String
    @Environment(AppContainer.self) private var app
    @State private var selectedSource: SourceID?
    private var choices: [SourceRecommendations] { app.currentRecommendations.filter { $0.channels.contains { $0.genre == genre } } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text("各来源使用自己的分类与排序；选择喜欢的来源浏览。") .font(.subheadline).foregroundStyle(.secondary)
                Picker("漫画来源", selection: $selectedSource) {
                    Text("所有来源").tag(SourceID?.none)
                    ForEach(choices, id: \.sourceID) { Text(app.sourceName($0.sourceID)).tag(Optional($0.sourceID)) }
                }.pickerStyle(.menu)
                ForEach(choices.filter { selectedSource == nil || $0.sourceID == selectedSource }, id: \.sourceID) { snapshot in
                    if let channel = snapshot.channels.first(where: { $0.genre == genre }) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack { Text(app.sourceName(snapshot.sourceID)).font(.title2.bold()); Spacer(); NavigationLink("来源专栏", value: Route.sourceColumn(snapshot.sourceID)) }
                            CatalogChannelContents(sourceID: snapshot.sourceID, channel: channel).id(snapshot.sourceID.key + channel.id)
                        }
                    }
                }
                if choices.isEmpty { EmptyState(title: "当前没有可用来源", icon: "network", message: "返回推荐重新读取分类，其他来源仍可继续浏览。") }
            }.padding(24).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle(genre).onChange(of: choices.map(\.sourceID)) { _, ids in if let selectedSource, !ids.contains(selectedSource) { self.selectedSource = nil } }
    }
}
struct CatalogColumnView: View {
    let sourceID: SourceID
    let channelID: String
    @Environment(AppContainer.self) private var app
    private var snapshot: SourceRecommendations? { app.recommendationSnapshot(for: sourceID) }
    private var channel: CatalogChannel? { snapshot?.channels.first { $0.id == channelID } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let snapshot, let channel {
                    CatalogFreshness(snapshot: snapshot)
                    CatalogChannelContents(sourceID: sourceID, channel: channel).id(sourceID.key + String(snapshot.sourceRevision) + channelID)
                } else { EmptyState(title: "专栏当前不可用", icon: "network", message: "来源已更改或停用，请返回推荐刷新。") }
            }.padding(24).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle(channel.map { ( $0.genre ?? $0.title ) + " · " + app.sourceName(sourceID) } ?? "漫画专栏")
    }
}
private struct CatalogFreshness: View {
    let snapshot: SourceRecommendations
    @Environment(AppContainer.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(app.recommendationErrors[snapshot.sourceID] == nil ? "读取于" : "旧缓存 · 读取于") \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            if let error = app.recommendationErrors[snapshot.sourceID] { Text("来源读取失败：\(error)").font(.caption).foregroundStyle(.secondary) }
            ForEach(snapshot.notices, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
struct CatalogChannelContents: View {
    let sourceID: SourceID
    let channel: CatalogChannel
    @Environment(AppContainer.self) private var app
    @State private var works: [SourceWork] = []
    @State private var nextURL: URL?
    @State private var loadedURLs = Set<URL>()
    @State private var loading = false
    @State private var failure: String?
    @State private var sort: CatalogSort = .sourceDefault
    @State private var requestID = UUID()
    private var requestKey: String { channel.id + sort.rawValue }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if channel.sorts.count > 1 {
                Picker("排序", selection: $sort) { ForEach(channel.sorts, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 400).disabled(loading)
            } else { Text(channel.kind == .popular ? "原站榜单顺序" : "原站顺序").font(.caption).foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .top)], spacing: 14) {
                ForEach(works) { work in
                    Button { Task { await app.select(work) } } label: {
                        HStack(alignment: .top, spacing: 14) {
                            CoverView(url: work.coverURL, sourceWork: work, width: 68, height: 96)
                            VStack(alignment: .leading, spacing: 6) { Text(work.title).font(.headline).lineLimit(3); SourceBadge(name: app.sourceName(sourceID)); if !work.author.isEmpty { Text(work.author).font(.caption).foregroundStyle(.secondary) }; if app.openingResults.contains(work.id) { ProgressView("读取目录…").controlSize(.small) } }
                            Spacer(minLength: 0)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).disabled(app.openingResults.contains(work.id)).accessibilityLabel("打开 \(work.title) · \(app.sourceName(sourceID))")
                }
            }
            if loading { ProgressView("读取专栏…").frame(maxWidth: .infinity).padding() }
            if let failure { Text("读取失败：\(failure)").font(.subheadline).foregroundStyle(.secondary); Button("重试") { Task { await load(pageURL: nextURL) } }.buttonStyle(.bordered) }
            else if let nextURL { Button("加载下一页") { Task { await load(pageURL: nextURL) } }.buttonStyle(.borderedProminent).disabled(loading).accessibilityIdentifier("catalog-next-page") }
            else if !loading && !works.isEmpty { Text("原站当前未提供更多页面").font(.caption).foregroundStyle(.secondary) }
            else if !loading { Text("该分类暂未返回作品").foregroundStyle(.secondary) }
        }.task(id: requestKey) {
            works = []; nextURL = nil; loadedURLs = []; failure = nil; requestID = UUID(); loading = false
            await load(pageURL: nil)
        }
    }
    private func load(pageURL: URL?) async {
        guard !loading else { return }
        loading = true; failure = nil; let id = requestID
        defer { if requestID == id { loading = false } }
        do {
            let page = try await app.sources.catalogPage(sourceID: sourceID, channelID: channel.id, sort: sort, pageURL: pageURL)
            try Task.checkCancellation(); guard requestID == id else { return }
            var seen = Set(works.map(\.id)); works += page.works.filter { seen.insert($0.id).inserted }
            if let pageURL { loadedURLs.insert(pageURL) }
            if let next = page.nextURL, loadedURLs.contains(next) { nextURL = nil; failure = "原站分页重复，请返回后刷新此专栏。" }
            else { nextURL = page.nextURL }
        } catch is CancellationError { } catch { if requestID == id { failure = error.localizedDescription } }
    }
}
