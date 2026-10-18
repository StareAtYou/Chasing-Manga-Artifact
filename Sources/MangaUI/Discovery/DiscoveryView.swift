import SwiftUI
import MangaCore
struct DiscoveryView: View {
    @Environment(AppContainer.self) private var app
    @State private var query = ""
    private var selectedSources: Set<SourceID> { Set(app.discoverySearchScope.sourceIDs(in: app.sourceList)) }
    @State private var showSources = false
    @State private var showWorkURL = false
    @State private var showSearchFilter = false
    private var searchable: [Source] { app.discoverySearchSources }
    var body: some View {
        ScrollView { LazyVStack(alignment: .leading, spacing: 24) {
            searchScopeSelector
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { searchResults }
            else {
                if !app.validatedWorks.isEmpty { workGrid(title: "已验证的作品", works: app.validatedWorks) }
                if app.validatedWorks.isEmpty {
                    EmptyState(title: "寻找喜欢的漫画", icon: "magnifyingglass", message: "搜索作品名称、打开作品链接，或前往推荐浏览分类和来源专栏。")
                }
                Button("浏览推荐与分类") { app.section = .recommendations }.buttonStyle(.borderedProminent)
            }
        }.padding(24) }.navigationTitle("发现")
        .searchable(text: $query, prompt: "搜索漫画名称")
        .onChange(of: query) { _, _ in search() }
        .onChange(of: selectedSources, initial: true) { _, _ in
            search()
        }
        .toolbar {
            Button { Task { await app.prepareCatalog() } } label: { Label("刷新来源", systemImage: "arrow.clockwise") }.disabled(!app.catalogLoading.isEmpty)
            Button { showWorkURL = true } label: { Label("打开作品链接", systemImage: "link") }
            Button { showSources = true } label: { Label("管理漫画源", systemImage: "slider.horizontal.3") }
        }
        .sheet(isPresented: $showWorkURL) { OpenWorkURLSheet() }
        .sheet(isPresented: $showSources) { NavigationStack { SourceManagementView() } }
        .sheet(isPresented: $showSearchFilter) {
            NavigationStack {
                List {
                    Section {
                        Button("全选") { app.discoverySearchScope = .all }
                        Button("清空选择") { app.discoverySearchScope = .excluding(Set(searchable.map(\.id))) }
                    }
                    Section("参与搜索的漫画源") {
                        ForEach(searchable) { source in
                            Toggle(source.name, isOn: Binding(get: { selectedSources.contains(source.id) }, set: { enabled in
                                var selected = selectedSources
                                if enabled { selected.insert(source.id) } else { selected.remove(source.id) }
                                let excluded = Set(searchable.map(\.id)).subtracting(selected)
                                app.discoverySearchScope = excluded.isEmpty ? .all : .excluding(excluded)
                            }))
                        }
                    }
                }.navigationTitle("自定义搜索范围").toolbar { Button("完成") { showSearchFilter = false } }.frame(minWidth: 320, minHeight: 360)
            }
        }
        .onDisappear { app.cancelSearch() }
    }
    private var scopeTitle: String {
        switch app.discoverySearchScope {
        case .all: "全部漫画源"
        case .source(let id): app.sourceName(id)
        case .excluding: "自定义范围"
        }
    }
    private var searchScopeSelector: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("搜索范围", systemImage: "line.3.horizontal.decrease.circle").font(.subheadline)
                Spacer(minLength: 12)
                Menu {
                    Picker("搜索范围", selection: $app.discoverySearchScope) {
                        Text("全部漫画源").tag(SearchScope.all)
                        ForEach(searchable) { source in Text(source.name).tag(SearchScope.source(source.id)) }
                        if case .excluding = app.discoverySearchScope { Text("自定义范围").tag(app.discoverySearchScope) }
                        if case .source(let id) = app.discoverySearchScope, !searchable.contains(where: { $0.id == id }) {
                            Text("所选来源不可用").tag(app.discoverySearchScope).disabled(true)
                        }
                    }.pickerStyle(.inline)
                    Divider()
                    Button("自定义多源…") { showSearchFilter = true }
                } label: {
                    HStack(spacing: 6) {
                        Text(scopeTitle).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption.bold())
                    }.padding(.horizontal, 12).padding(.vertical, 10).background(.tint.opacity(0.08), in: Capsule())
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)
                #endif
                .accessibilityLabel("搜索范围：\(scopeTitle)").accessibilityIdentifier("discovery.searchScope")
            }
            Text(selectedSources.isEmpty ? "当前范围没有可搜索来源" : "将在 \(selectedSources.count) 个已启用的漫画源中搜索，结果保留来源标识。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var searchResults: some View {
        if app.searching { ProgressView("正在搜索，结果会逐步显示…") }
        if selectedSources.isEmpty { Text("当前范围没有可搜索的漫画源；请选择其他来源、全部漫画源，或在来源管理中检查启用状态。").foregroundStyle(.secondary) }
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
    private func search() { app.searchDiscovery(query) }
}
