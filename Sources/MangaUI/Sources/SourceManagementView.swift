import SwiftUI
import WebKit
import MangaCore
struct SourceManagementView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false
    @State private var editing: Source?
    @State private var visibleSource: Source?
    @State private var deleting: Source?
    var body: some View {
        ScrollView { LazyVStack(spacing: 20) { ForEach(app.sourceList) { source in VStack(alignment: .leading, spacing: 10) {
            HStack { Text(source.name).font(.headline); Spacer(); Toggle("启用 \(source.name)", isOn: Binding(get: { source.enabled }, set: { value in Task { await app.setEnabled(value, sourceID: source.id) } })).labelsHidden() }
            Text(source.baseURL.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack { if source.capabilities.contains(.browse) { SourceBadge(name: "可浏览") }; if source.capabilities.contains(.search) { SourceBadge(name: "可搜索") }; if let binding = source.binding { SourceBadge(name: binding.needsRetest ? "需要重新检测" : (binding.level == .limited ? "有限验证" : "已验证")) } else { SourceBadge(name: "候选来源") } }
            HStack { Button("编辑 / 检测") { editing = source }; Button("检查浏览与搜索") { Task { await app.inspectSource(source.id) } }.disabled(!source.enabled); Button("打开来源页面") { visibleSource = source }; Button("删除", role: .destructive) { deleting = source } }.font(.caption).buttonStyle(.borderless)
            if app.catalogLoading.contains(source.id) { ProgressView("正在检查浏览与搜索…") }
            ForEach(Array((app.catalogErrors[source.id] ?? [:]).keys.sorted()), id: \.self) { key in Text("\(key == "search" ? "搜索" : "浏览")：\(app.catalogErrors[source.id]?[key]?.localizedDescription ?? "")").font(.caption).foregroundStyle(.secondary) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14)) } }.padding(20) }.navigationTitle("漫画源").toolbar { Button { showAdd = true } label: { Label("添加源", systemImage: "plus") }; Button("完成") { dismiss() } }
        .onChange(of: app.path) { _, _ in dismiss() }
        .sheet(isPresented: $showAdd) { SourceEditorSheet(source: nil) }.sheet(item: $editing) { SourceEditorSheet(source: $0) }.sheet(item: $visibleSource) { SourceWebView(source: $0) }
        .confirmationDialog("删除源配置后，书架、进度和已下载章节会保留。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) { Button("删除源配置", role: .destructive) { if let deleting { Task { await app.removeSource(deleting.id) } }; deleting = nil }; Button("取消", role: .cancel) { deleting = nil } }
    }
}
struct SourceEditorSheet: View {
    let source: Source?
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var currentSource: Source?
    @State private var name: String
    @State private var url: String
    @State private var samples = ""
    @State private var report: DetectionReport?
    @State private var detecting = false
    @State private var job: Task<Void, Never>?
    @State private var localError: String?
    init(source: Source?) { self.source = source; _currentSource = State(initialValue: source); _name = State(initialValue: source?.name ?? ""); _url = State(initialValue: source?.baseURL.absoluteString ?? "") }
    var body: some View {
        NavigationStack { Form {
            Section("来源信息") { TextField("名称", text: $name); TextField("https://漫画网站", text: $url).textContentType(.URL); Text("输入网站地址，应用会尝试已有解析方式。").font(.caption).foregroundStyle(.secondary) }
            Section("样本链接（可选）") { TextEditor(text: $samples).frame(minHeight: 80); Text("每行一个漫画详情链接。不同作品的样本越充分，检测结果越可靠。").font(.caption).foregroundStyle(.secondary) }
            if detecting { ProgressView("正在检测作品、章节与正文…"); Button("取消检测") { job?.cancel() } }
            else { Button(currentSource == nil ? "添加并检测" : "保存并重新检测") { detect() }.buttonStyle(.borderedProminent) }
            if let localError { Text(localError).foregroundStyle(.red) }
            if let report { DetectionResultView(report: report) }
        }.formStyle(.grouped).navigationTitle(source == nil ? "添加漫画源" : "编辑漫画源").toolbar { Button("完成") { job?.cancel(); dismiss() } }.frame(minWidth: 320, minHeight: 440) }.onDisappear { job?.cancel() }
    }
    private func detect() {
        guard let base = URL(string: url), let canonical = try? canonicalSourceURL(base) else { localError = MangaError.invalidURL.localizedDescription; return }
        let lines = samples.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let urls = lines.compactMap(URL.init(string:)); guard urls.count == lines.count else { localError = "有样本链接格式不正确"; return }
        detecting = true; localError = nil; report = nil
        job = Task { @MainActor in
            defer { detecting = false }
            do {
                let edited: Source
                if let currentSource { edited = try await app.store.editSource(id: currentSource.id, name: name, baseURL: canonical, expectedRevision: currentSource.revision) }
                else { edited = Source(name: name.isEmpty ? canonical.host ?? "漫画源" : name, baseURL: canonical); try await app.store.save(source: edited) }
                self.currentSource = edited
                report = try await app.sources.retest(sourceID: edited.id, samples: urls)
                if !Task.isCancelled { await app.inspectSource(edited.id) }
            } catch is CancellationError { } catch { localError = error.localizedDescription }
            if let id = self.currentSource?.id { self.currentSource = try? await app.store.source(id: id) }
            try? await app.refresh()
        }
    }
}
struct SourceWebView: View {
    let source: Source
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    var body: some View { NavigationStack { NativeSourceWebView(webView: app.web.session(for: source).webView).navigationTitle(source.name).toolbar { Button("刷新访问状态") { Task { await app.perform { _ = try await app.web.session(for: source).snapshot(); app.message = "访问状态已更新，可以重新检测或重试。" } } }; Button("完成") { dismiss() } }.task { await app.perform { try app.web.session(for: source).open(source.baseURL) } } }.frame(minWidth: 320, minHeight: 500) }
}
#if os(macOS)
struct NativeSourceWebView: NSViewRepresentable { let webView: WKWebView; func makeNSView(context: Context) -> WKWebView { webView }; func updateNSView(_ nsView: WKWebView, context: Context) { } }
#else
struct NativeSourceWebView: UIViewRepresentable { let webView: WKWebView; func makeUIView(context: Context) -> WKWebView { webView }; func updateUIView(_ uiView: WKWebView, context: Context) { } }
#endif
