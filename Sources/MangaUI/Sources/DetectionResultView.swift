import SwiftUI
import MangaCore
struct DetectionResultView: View {
    let report: DetectionReport
    @Environment(AppContainer.self) private var app
    @State private var chosen = false
    var body: some View { Section("检测结果") { Label(title, systemImage: [.verified, .limited].contains(report.status) ? "checkmark.circle" : "info.circle"); if let error = report.error { Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary) }
        if report.status == .limited { Text("已绑定解析方式，但样本不足。建议补充另一部作品的链接后再检测。").font(.caption).foregroundStyle(.secondary) }
        if report.status == .needsSamples || report.status == .unsupported { Text("请补充详情样本链接；未匹配成功的来源不会被标为可阅读。").font(.caption).foregroundStyle(.secondary) }
        ForEach(Array(report.candidates.enumerated()), id: \.element.id) { index, candidate in VStack(alignment: .leading, spacing: 8) { Text("方式 \(index + 1) · \(candidate.binding.sampledWorks) 部作品 / \(candidate.binding.sampledChapters) 章").font(.subheadline); Text(candidate.works.map { $0.work.title }.joined(separator: "、")).font(.caption); ScrollView(.horizontal) { HStack { ForEach(Array(candidate.previewPages.prefix(4).enumerated()), id: \.offset) { _, url in AsyncImage(url: url) { phase in if let image = phase.image { image.resizable().scaledToFit() } else { Image(systemName: "photo").foregroundStyle(.secondary) } }.frame(width: 90, height: 120) } } }
            if report.status == .ambiguous { Button(chosen ? "已选择" : "使用这套正文解析") { Task { await app.perform { try await app.sources.choose(parserID: candidate.id, from: report); chosen = true; try await app.refresh() } } }.disabled(chosen) }
        } }
    } }
    private var title: String { switch report.status { case .verified: "解析成功并已绑定"; case .limited: "解析成功，有限验证"; case .ambiguous: "正文结果不一致，请检查预览后选择"; case .needsSamples: "需要样本链接"; case .accessFailure: "当前无法访问来源内容"; case .unsupported: "尚未找到匹配方式"; case .cancelled: "检测已取消" } }
}
