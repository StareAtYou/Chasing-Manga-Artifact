import SwiftUI
import MangaCore
struct DiscoveryView: View {
    @Environment(AppContainer.self) private var app
    @State private var query = ""
    @State private var selectedSources = Set<SourceID>()
    @State private var browsing: [SourceWork] = []
    @State private var showSources = false
    @State private var showWorkURL = false
    var body: some View {
        List {
            Section("漫画来源") { ForEach(app.sourceList) { source in HStack { Toggle(source.name, isOn: Binding(get: { selectedSources.contains(source.id) }, set: { if $0 { selectedSources.insert(source.id) } else { selectedSources.remove(source.id) }; search() })).disabled(!source.enabled || !source.capabilities.contains(.search)); Spacer(); Button("浏览") { Task { await app.perform { let adapter = try await app.sources.adapter(for: source.id); browsing = try await adapter.browse(context: app.sources.context(for: source.id)) } } }.disabled(!source.enabled) } }
                if !app.sourceList.contains(where: { $0.enabled && $0.capabilities.contains(.search) }) { Text("来源的搜索能力尚未确认。打开源管理，点击检查浏览与搜索。").font(.caption).foregroundStyle(.secondary) }
            }
            if !app.validatedWorks.isEmpty { Section("已验证的作品") { ForEach(app.validatedWorks) { work in Button { Task { await app.select(work) } } label: { VStack(alignment: .leading) { Text(work.title); SourceBadge(name: app.sourceName(work.id.sourceID)) } }.buttonStyle(.borderless) } } }
            if app.searching { ProgressView("正在搜索…") }
            ForEach(app.searchErrors.keys.sorted(by: { $0.key < $1.key }), id: \.self) { id in Label("\(app.sourceName(id))：\(app.searchErrors[id] ?? "")", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary) }
            Section(query.isEmpty ? "浏览漫画" : "搜索结果") { ForEach(query.isEmpty ? browsing : app.searchResults) { work in Button { Task { await app.select(work) } } label: { HStack(spacing: 14) { CoverView(url: work.coverURL).scaleEffect(0.6).frame(width: 60, height: 84); VStack(alignment: .leading, spacing: 6) { Text(work.title).font(.headline); SourceBadge(name: app.sourceName(work.id.sourceID)); if !work.author.isEmpty { Text(work.author).font(.caption).foregroundStyle(.secondary) } } }.padding(.vertical, 4) }.buttonStyle(.plain) } }
        }.navigationTitle("发现").searchable(text: $query, prompt: "漫画名称").onChange(of: query) { _, _ in search() }
        .toolbar { Button { showWorkURL = true } label: { Label("打开作品链接", systemImage: "link") }; Button { showSources = true } label: { Label("管理漫画源", systemImage: "slider.horizontal.3") } }
        .sheet(isPresented: $showWorkURL) { OpenWorkURLSheet() }
        .sheet(isPresented: $showSources) { NavigationStack { SourceManagementView() } }.onDisappear { app.cancelSearch() }
        .task { selectedSources = Set(app.sourceList.filter { $0.enabled && $0.capabilities.contains(.search) }.map(\.id)) }
    }
    private func search() { app.searchFor(query, sourceIDs: Array(selectedSources)) }
}
