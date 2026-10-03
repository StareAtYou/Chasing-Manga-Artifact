import SwiftUI
import MangaCore
struct RecommendationsView: View {
    @Environment(AppContainer.self) private var app
    @State private var showSources = false
    private var snapshots: [SourceRecommendations] { app.currentRecommendations }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Date.now.formatted(date: .complete, time: .omitted)).font(.subheadline).foregroundStyle(.secondary)
                    Text("发现下一部好漫画").font(.largeTitle.bold())
                    Text("按各来源的真实榜单和分类浏览，自行选择阅读来源。") .font(.subheadline).foregroundStyle(.secondary)
                }
                if !featured.isEmpty { featureCards }
                if !app.recommendationGenres.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("按分类发现").font(.title2.bold())
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 10) {
                            ForEach(app.recommendationGenres, id: \.self) { genre in
                                NavigationLink(value: Route.genreColumn(genre)) { Text(genre).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14).background(.teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 14)) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                ForEach(snapshots, id: \.sourceID) { snapshot in
                    ForEach(snapshot.sections.filter { !$0.works.isEmpty && $0.channel.kind == .popular }) { section in
                        recommendationRail(section, sourceID: snapshot.sourceID, subtitle: "原站榜单 · \(app.sourceName(snapshot.sourceID))")
                    }
                    ForEach(app.genrePreviews[snapshot.sourceID] ?? []) { section in
                        recommendationRail(section, sourceID: snapshot.sourceID, subtitle: "\(app.sourceName(snapshot.sourceID)) · \(section.channel.sorts.contains(.popularity) ? "人气顺序" : "原站顺序")")
                    }
                    if !snapshot.sections.contains(where: { $0.channel.kind == .popular }) {
                        ForEach(snapshot.sections.prefix(1)) { section in recommendationRail(section, sourceID: snapshot.sourceID, subtitle: "来源浏览 · \(app.sourceName(snapshot.sourceID))") }
                    }
                }
                sourceColumns
                if snapshots.isEmpty && !app.recommendationLoading.isEmpty { ProgressView("正在读取来源分类与推荐…").frame(maxWidth: .infinity).padding() }
                if snapshots.isEmpty && app.recommendationLoading.isEmpty { EmptyState(title: "暂未取得最新推荐", icon: "network", message: "重试来源，或在源管理中完成验证；已下载漫画仍在书架中。") }
                if !app.cachedRecommendations.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("上次保存的内容").font(.title2.bold())
                        Text("这些内容来自上次缓存，正在刷新或来源当前不可用，内容可能已过期。") .foregroundStyle(.secondary)
                        ForEach(app.cachedRecommendations, id: \.sourceID) { snapshot in
                            ForEach(snapshot.sections.prefix(1)) { section in recommendationRail(section, sourceID: snapshot.sourceID, subtitle: "缓存 · \(app.sourceName(snapshot.sourceID)) · \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))") }
                        }
                    }
                }
            }.padding(24).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle("推荐")
        .toolbar {
            Button { Task { await app.prepareRecommendations(force: true) } } label: { Label("刷新推荐", systemImage: "arrow.clockwise") }.disabled(!app.recommendationLoading.isEmpty)
            Button { showSources = true } label: { Label("管理漫画源", systemImage: "slider.horizontal.3") }
        }
        .sheet(isPresented: $showSources) { NavigationStack { SourceManagementView() } }
        .task(id: app.section == .recommendations) { if app.section == .recommendations { await app.prepareRecommendations() } }
        .refreshable { await app.prepareRecommendations(force: true) }
    }
    private var featured: [(SourceID, CatalogSection, SourceWork)] {
        snapshots.compactMap { snapshot in
            guard let section = snapshot.sections.first(where: { $0.channel.kind == .popular && !$0.works.isEmpty }), let work = section.works.first else { return nil }
            return (snapshot.sourceID, section, work)
        }
    }
    private var featureCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(featured, id: \.0) { source, section, work in
                    Button { Task { await app.select(work) } } label: {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("\(app.sourceName(source)) · \(section.channel.title)").font(.subheadline.bold()).foregroundStyle(.secondary)
                            Text(freshness(source)).font(.caption).foregroundStyle(.secondary)
                            HStack(alignment: .center, spacing: 18) {
                                CoverView(url: work.coverURL, sourceWork: work, width: 104, height: 148)
                                VStack(alignment: .leading, spacing: 10) { Text(work.title).font(.title2.bold()).lineLimit(3); Text("从原站榜单开始探索").font(.subheadline).foregroundStyle(.secondary); Label("查看漫画", systemImage: "arrow.right.circle.fill").font(.subheadline.bold()).foregroundStyle(.teal) }
                            }
                        }.padding(22).frame(width: 310, alignment: .leading).background(LinearGradient(colors: [.teal.opacity(0.18), .blue.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
                    }.buttonStyle(.plain).disabled(app.openingResults.contains(work.id)).accessibilityLabel("推荐 \(work.title) · \(app.sourceName(source))")
                }
            }
        }
    }
    private func recommendationRail(_ section: CatalogSection, sourceID: SourceID, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { VStack(alignment: .leading, spacing: 4) { Text(section.channel.genre ?? section.channel.title).font(.title2.bold()); Text(subtitle + " · " + freshness(sourceID)).font(.caption).foregroundStyle(.secondary) }; Spacer(); NavigationLink("查看全部", value: Route.catalogChannel(sourceID, section.channel.id)).font(.subheadline) }
            ScrollView(.horizontal, showsIndicators: false) { LazyHStack(alignment: .top, spacing: 18) { ForEach(section.works.prefix(16)) { work in RecommendationCoverCard(work: work) } } }
        }
    }
    private func freshness(_ sourceID: SourceID) -> String {
        let prefix = app.isRecommendationCached(sourceID) ? "缓存 · " : ""
        return prefix + "读取于 " + (app.recommendationSnapshot(for: sourceID)?.fetchedAt.formatted(date: .abbreviated, time: .shortened) ?? "未知")
    }
    private var sourceColumns: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("探索来源专栏").font(.title2.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .top)], spacing: 12) {
                ForEach(app.sourceList.filter { $0.enabled && !$0.removed }) { source in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(source.name).font(.headline); Spacer(); if app.recommendationLoading.contains(source.id) { ProgressView().controlSize(.small) } }
                        if let snapshot = app.recommendationSnapshot(for: source.id) {
                            Text("\(snapshot.channels.filter { $0.kind == .genre }.count) 个原站分类 · \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            NavigationLink("进入专栏", value: Route.sourceColumn(source.id)).buttonStyle(.bordered)
                            ForEach(snapshot.notices, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        }
                        if let error = app.recommendationErrors[source.id] { Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3); Button("重试此来源") { Task { await app.refreshRecommendations(sourceID: source.id) } }.buttonStyle(.bordered) }
                        else if app.recommendationSnapshot(for: source.id) == nil && !app.recommendationLoading.contains(source.id) { Text("尚未取得分类内容，可在源管理中检查解析。") .font(.caption).foregroundStyle(.secondary) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }
}
struct RecommendationCoverCard: View {
    let work: SourceWork
    @Environment(AppContainer.self) private var app
    var body: some View {
        Button { Task { await app.select(work) } } label: {
            VStack(alignment: .leading, spacing: 8) { CoverView(url: work.coverURL, sourceWork: work, width: 112, height: 156); Text(work.title).font(.subheadline.bold()).lineLimit(2); if app.openingResults.contains(work.id) { ProgressView().controlSize(.small) } }
                .frame(width: 112, alignment: .leading)
        }.buttonStyle(.plain).disabled(app.openingResults.contains(work.id)).accessibilityLabel("打开 \(work.title) · \(app.sourceName(work.id.sourceID))")
    }
}
