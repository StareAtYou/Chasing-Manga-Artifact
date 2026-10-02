import SwiftUI
import MangaCore
struct SourceAssociationSheet: View {
    let work: Work
    let existingIDs: Set<SourceWorkID>
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var results: [SourceWork] = []
    @State private var errors: [SourceID: String] = [:]
    @State private var engine: SearchService?
    @State private var job: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var searching = false
    @State private var linking = false
    @State private var candidate: SourceWork?
    @State private var failure: String?
    init(work: Work, existingIDs: Set<SourceWorkID>) { self.work = work; self.existingIDs = existingIDs; _query = State(initialValue: work.title) }
    var body: some View {
        NavigationStack {
            List {
                Section { Text("搜索其他来源，核对作品与版本后确认关联。每个来源保留自己的目录和阅读进度。").font(.caption).foregroundStyle(.secondary) }
                if searching { ProgressView("正在查找其他来源…") }
                if linking { ProgressView("正在关联来源…") }
                ForEach(errors.keys.sorted(by: { $0.key < $1.key }), id: \.self) { id in Text("\(app.sourceName(id))：\(errors[id] ?? "")").font(.caption).foregroundStyle(.secondary) }
                ForEach(results.filter { !existingIDs.contains($0.id) }) { result in
                    Button { candidate = result } label: { HStack(spacing: 14) { CoverView(url: result.coverURL, sourceWork: result, width: 50, height: 70); VStack(alignment: .leading, spacing: 6) { Text(result.title).font(.headline); SourceBadge(name: app.sourceName(result.id.sourceID)); if !result.author.isEmpty { Text(result.author).font(.caption) } } } }.buttonStyle(.borderless).disabled(linking)
                }
                if !searching && results.filter({ !existingIDs.contains($0.id) }).isEmpty { Text("暂未找到其他来源。可以修改关键词，或先添加并验证新的漫画源。").foregroundStyle(.secondary) }
            }.navigationTitle("关联其他来源").searchable(text: $query, prompt: "作品名称或别名")
                .toolbar { Button("完成") { dismiss() }.disabled(linking) }
                .onChange(of: query) { _, _ in search() }
                .task { engine = SearchService(store: app.store, sources: app.sources); search() }
                .onDisappear { job?.cancel(); if let engine { Task { await engine.cancel() } } }
                .confirmationDialog("将所选来源关联到《\(work.title)》？请确认是同一作品和版本。", isPresented: Binding(get: { candidate != nil }, set: { if !$0 { candidate = nil } }), titleVisibility: .visible) {
                    Button("确认关联") { if let candidate { Task { linking = true; await app.linkResult(candidate, to: work.id); linking = false; if let message = app.message { failure = message; app.message = nil } else { dismiss() } } }; candidate = nil }
                    Button("取消", role: .cancel) { candidate = nil }
                }
                .alert("无法关联", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("好", role: .cancel) { failure = nil } } message: { Text(failure ?? "") }
        }.frame(minWidth: 320, minHeight: 440)
    }
    private func search() {
        job?.cancel(); generation = UUID(); let token = generation; results = []; errors = [:]
        guard let engine, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { searching = false; return }
        let text = query; let ids = app.sourceList.filter { $0.enabled && $0.capabilities.contains(.search) }.map(\.id); searching = true
        job = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            for await event in await engine.search(query: text, sourceIDs: ids, queryID: token) {
                guard !Task.isCancelled, generation == token else { break }
                switch event { case .results(_, _, let works): results += works; case .failure(_, let source, let error): errors[source] = error.localizedDescription; case .finished: searching = false }
            }
            if generation == token { searching = false }
        }
    }
}
