import SwiftUI
import MangaCore
struct DiscoveryView: View {
    @Environment(AppContainer.self) private var app
    @State private var query = ""
    @State private var selectedSources = Set<SourceID>()
    @State private var knownSearchSources = Set<SourceID>()
    @State private var browseSource: SourceID?
    @State private var limits: [SourceID: Int] = [:]
    @State private var showSources = false
    @State private var showWorkURL = false
    @State private var visibleSource: Source?
    private var searchable: Set<SourceID> { Set(app.sourceList.filter { $0.enabled && $0.capabilities.contains(.search) }.map(\.id)) }
    var body: some View {
        ScrollView { LazyVStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("漫画来源").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(app.sourceList) { source in sourceCard(source) }
                }
            }
            if !query.isEmpty { searchResults }
            else {
                if !app.validatedWorks.isEmpty { workGrid(title: "已验证的作品", works: app.validatedWorks) }
                ForEach(app.sourceList.filter { $0.enabled && (browseSource == nil || browseSource == $0.id) }) { source in
                    let works = app.browsingBySource[source.id] ?? []
                    if !works.isEmpty {
                        workGrid(title: source.name, works: Array(works.prefix(limits[source.id] ?? 24)))
                        if works.count > (limits[source.id] ?? 24) { Button("查看更多 · 共 \(works.count) 部") { limits[source.id] = (limits[source.id] ?? 24) + 48 }.buttonStyle(.bordered) }
                    }
                }
                if app.browsingBySource.values.allSatisfy(\.isEmpty), app.catalogLoading.isEmpty {
                    EmptyState(title: "暂未取得浏览内容", icon: "network", message: "可以重试来源检查，或从链接入口打开漫画详情。")
                }
            }
        }.padding(24) }.navigationTitle("发现")
        .searchable(text: $query, prompt: "跨源搜索漫画名称")
        .onChange(of: query) { _, _ in search() }
        .onChange(of: searchable, initial: true) { _, available in
            selectedSources.formUnion(available.subtracting(knownSearchSources)); selectedSources.formIntersection(available); knownSearchSources.formUnion(available)
            search()
        }
        .toolbar {
            Button { browseSource = nil; Task { await app.prepareCatalog() } } label: { Label("刷新来源", systemImage: "arrow.clockwise") }.disabled(!app.catalogLoading.isEmpty)
            Button { showWorkURL = true } label: { Label("打开作品链接", systemImage: "link") }
            Button { showSources = true } label: { Label("管理漫画源", systemImage: "slider.horizontal.3") }
        }
        .sheet(isPresented: $showWorkURL) { OpenWorkURLSheet() }
        .sheet(isPresented: $showSources) { NavigationStack { SourceManagementView() } }
        .sheet(item: $visibleSource) { SourceWebView(source: $0) }
        .onDisappear { app.cancelSearch() }
    }
    private func sourceCard(_ source: Source) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(source.name).font(.headline); Spacer(); if app.catalogLoading.contains(source.id) { ProgressView().controlSize(.small) } }
            Toggle("参与跨源搜索", isOn: Binding(get: { selectedSources.contains(source.id) }, set: { if $0 { selectedSources.insert(source.id) } else { selectedSources.remove(source.id) }; search() })).font(.caption).disabled(!source.enabled || !source.capabilities.contains(.search))
            if source.enabled, let count = app.browsingBySource[source.id]?.count, count > 0 { Text("可浏览 · \(count) 部作品").font(.caption).foregroundStyle(.secondary) }
            Text(source.baseURL.host ?? source.name).font(.caption).foregroundStyle(.secondary)
            if !source.enabled { Text("已停用").font(.caption).foregroundStyle(.secondary) }
            else if let errors = app.catalogErrors[source.id], !errors.isEmpty {
                ForEach(errors.keys.sorted(), id: \.self) { kind in Text("\(kind == "search" ? "搜索" : "浏览")：\(errors[kind]?.localizedDescription ?? "")").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            } else if source.capabilities.contains(.search) { Text("可跨源搜索 · \(app.browsingBySource[source.id]?.count ?? 0) 部浏览作品").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("浏览") { query = ""; browseSource = source.id; if app.browsingBySource[source.id]?.isEmpty != false { Task { await app.inspectSource(source.id) } } }
                Button("重新检查") { Task { await app.inspectSource(source.id) } }
                Button("来源页面 / 验证") { visibleSource = source }
            }.buttonStyle(.bordered).disabled(!source.enabled || app.catalogLoading.contains(source.id))
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
    @ViewBuilder private var searchResults: some View {
        if app.searching { ProgressView("正在搜索，结果会逐步显示…") }
        if selectedSources.isEmpty { Text("尚无选中的可搜索来源；请检查来源状态，或直接打开作品链接。").foregroundStyle(.secondary) }
        ForEach(app.searchErrors.keys.sorted(by: { $0.key < $1.key }), id: \.self) { id in Label("\(app.sourceName(id))：\(app.searchErrors[id] ?? "")", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary) }
        workGrid(title: "搜索结果 · \(app.searchResults.count)", works: app.searchResults)
        if !app.searching && app.searchResults.isEmpty && !selectedSources.isEmpty { EmptyState(title: "没有找到漫画", icon: "magnifyingglass", message: "试试作品别名或更短的关键词。") }
    }
    private func workGrid(title: String, works: [SourceWork]) -> some View {
        VStack(alignment: .leading, spacing: 14) { Text(title).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), alignment: .leading)], spacing: 14) {
                ForEach(works) { work in Button { Task { await app.select(work) } } label: {
                    HStack(spacing: 14) { CoverView(url: work.coverURL, sourceWork: work, width: 60, height: 84)
                        VStack(alignment: .leading, spacing: 6) { Text(work.title).font(.headline).lineLimit(2); SourceBadge(name: app.sourceName(work.id.sourceID)); if !work.author.isEmpty { Text(work.author).font(.caption).foregroundStyle(.secondary) }; if app.openingResults.contains(work.id) { ProgressView("读取目录…").controlSize(.small) } }
                        Spacer(minLength: 0)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).disabled(app.openingResults.contains(work.id)).accessibilityLabel("打开 \(work.title) · \(app.sourceName(work.id.sourceID))") }
            }
        }
    }
    private func search() { app.searchFor(query, sourceIDs: Array(selectedSources)) }
}
