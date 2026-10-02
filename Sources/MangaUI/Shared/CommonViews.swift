import SwiftUI
import MangaCore
import MangaPlatform
struct CoverView: View {
    let url: URL?
    var sourceWork: SourceWork? = nil
    var width: CGFloat = 100
    var height: CGFloat = 140
    @Environment(AppContainer.self) private var app
    @State private var tiles: [ImageTile] = []
    var body: some View {
        Group {
            if let tile = tiles.first { Image(decorative: tile.image, scale: 1).resizable().scaledToFill() }
            else if sourceWork == nil { AsyncImage(url: url) { phase in if let image = phase.image { image.resizable().scaledToFill() } else { placeholder } } }
            else { placeholder }
        }.frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
            .task(id: (sourceWork?.id.key ?? "") + (url?.absoluteString ?? "")) {
                guard var work = sourceWork else { return }; work.coverURL = url ?? work.coverURL; guard work.coverURL != nil else { return }
                do {
                    let file = try await app.coverFile(work: work)
                    let metadata = try await Task.detached { try ImageVerifier().verify(Data(contentsOf: file)) }.value
                    let decoded = try await Task.detached { try TiledImageDecoder().decode(file: file, viewport: PixelRect(x: 0, y: 0, width: metadata.width, height: metadata.height), targetWidth: 200) }.value
                    try Task.checkCancellation(); tiles = decoded
                } catch { }
            }
    }
    private var placeholder: some View { ZStack { Rectangle().fill(.teal.opacity(0.09)); Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.teal.opacity(0.5)) } }
}
struct SourceBadge: View { let name: String; var body: some View { Text(name).font(.caption).padding(.horizontal, 8).padding(.vertical, 4).background(.teal.opacity(0.1), in: Capsule()).foregroundStyle(.teal) } }
struct EmptyState: View { let title: String; let icon: String; let message: String; var body: some View { ContentUnavailableView(title, systemImage: icon, description: Text(message)).frame(maxWidth: .infinity, maxHeight: .infinity) } }
