import SwiftUI
import MangaCore
struct DiscoveryView: View {
    @Environment(AppContainer.self) private var app
    @State private var query = ""
    @State private var excludedSources = Set<SourceID>()
    private var selectedSources: Set<SourceID> { searchable.subtracting(excludedSources) }
    @State private var showSources = false
    @State private var showWorkURL = false
    @State private var showSearchFilter = false
    private var searchable: Set<SourceID> { Set(app.sourceList.filter { $0.enabled && $0.capabilities.contains(.search) }.map(\.id)) }
    var body: some View {
        ScrollView { LazyVStack(alignment: .leading, spacing: 24) {
            if !query.isEmpty { searchResults }
            else {
                if !app.validatedWorks.isEmpty { workGrid(title: "已验证的作品", works: app.validatedWorks) }
                if app.validatedWorks.isEmpty {
                    EmptyState(title: "寻找喜欢的漫画", icon: "magnifyingglass", message: "搜索作品名称、打开作品链接，或前往推荐浏览分类和来源专栏。")
                }
                Button("浏览推荐与分类") { app.section = .recommendations }.buttonStyle(.borderedProminent)
            }
        }.padding(24) }.navigationTitle("发现")
        .searchable(text: $query, prompt: "跨源搜索漫画名称")
        .onChange(of: query) { _, _ in search() }
        .onChange(of: searchable, initial: true) { _, _ in
            search()
        }
        .toolbar {
            Button { Task { await app.prepareCatalog() } } label: { Label("刷新来源", systemImage: "arrow.clockwise") }.disabled(!app.catalogLoading.isEmpty)
            Button { showSearchFilter = true } label: { Label("搜索范围", systemImage: "line.3.horizontal.decrease.circle") }
            Button { showWorkURL = true } label: { Label("打开作品链接", systemImage: "link") }
            Button { showSources = true } label: { Label("管理漫画源", systemImage: "slider.horizontal.3") }
        }
        .sheet(isPresented: $showWorkURL) { OpenWorkURLSheet() }
        .sheet(isPresented: $showSources) { NavigationStack { SourceManagementView() } }
        .sheet(isPresented: $showSearchFilter) {
            NavigationStack {
                List(app.sourceList.filter { searchable.contains($0.id) }) { source in
                    Toggle(source.name, isOn: Binding(get: { selectedSources.contains(source.id) }, set: { if $0 { excludedSources.remove(source.id) } else { excludedSources.insert(source.id) }; search() }))
                }.navigationTitle("参与跨源搜索的来源").toolbar { Button("完成") { showSearchFilter = false } }.frame(minWidth: 320, minHeight: 360)
            }
        }
        .onDisappear { app.cancelSearch() }
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
