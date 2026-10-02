import SwiftUI
import MangaCore
import MangaPlatform
struct DetectionPreviewImage: View {
    let report: DetectionReport
    let candidate: DetectionCandidate
    let page: PageResource
    @Environment(AppContainer.self) private var app
    @State private var tiles: [ImageTile] = []
    @State private var failure: String?
    @State private var retry = 0
    var body: some View {
        VStack(spacing: 0) {
            if let failure { Image(systemName: "exclamationmark.triangle"); Text(failure).font(.caption2).lineLimit(2); Button("重试") { retry += 1 } }
            else if tiles.isEmpty { ProgressView() }
            else { ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in Image(decorative: tile.image, scale: 1).resizable().scaledToFit() } }
        }.frame(width: 90, height: 120).accessibilityLabel("解析方式 \(candidate.id) 的正文预览")
            .task(id: retry) { do {
                let file = try await app.previewFile(report: report, candidate: candidate, page: page)
                let metadata = try await Task.detached { try ImageVerifier().verify(Data(contentsOf: file)) }.value
                tiles = try await Task.detached { try TiledImageDecoder().decode(file: file, viewport: PixelRect(x: 0, y: 0, width: metadata.width, height: metadata.height), targetWidth: 180) }.value
                try Task.checkCancellation(); failure = nil
            } catch is CancellationError { } catch { failure = error.localizedDescription } }
    }
}
