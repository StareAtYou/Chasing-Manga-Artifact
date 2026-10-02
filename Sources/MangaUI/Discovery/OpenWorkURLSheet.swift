import SwiftUI
import MangaCore
struct OpenWorkURLSheet: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var sourceID: SourceID?
    @State private var url = ""
    @State private var loading = false
    @State private var failure: String?
    var body: some View {
        NavigationStack { Form {
            Picker("漫画来源", selection: $sourceID) { ForEach(app.sourceList.filter(\.enabled)) { source in Text(source.name).tag(Optional(source.id)) } }
            TextField("作品详情 URL", text: $url).textContentType(.URL)
            Text("来源不支持搜索或浏览时，可以直接输入作品详情链接。").font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.red) }
            Button(loading ? "正在打开…" : "打开作品") { Task { loading = true; defer { loading = false }; guard let id = sourceID, let value = URL(string: url) else { failure = "请选择来源并输入有效网址"; return }; let count = app.path.count; await app.openWorkURL(value, sourceID: id); if app.path.count > count { dismiss() } else { failure = app.message ?? "当前链接无法打开"; app.message = nil } } }.disabled(loading)
        }.formStyle(.grouped).navigationTitle("打开作品链接").toolbar { Button("完成") { dismiss() } }.frame(minWidth: 320, minHeight: 280) }.onAppear { sourceID = app.sourceList.first(where: \.enabled)?.id }
    }
}
