import SwiftUI
import MangaCore
struct CoverView: View {
    let url: URL?
    var body: some View { AsyncImage(url: url) { phase in if let image = phase.image { image.resizable().scaledToFill() } else { ZStack { Rectangle().fill(.teal.opacity(0.09)); Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.teal.opacity(0.5)) } } }.frame(width: 100, height: 140).clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true) }
}
struct SourceBadge: View { let name: String; var body: some View { Text(name).font(.caption).padding(.horizontal, 8).padding(.vertical, 4).background(.teal.opacity(0.1), in: Capsule()).foregroundStyle(.teal) } }
struct EmptyState: View { let title: String; let icon: String; let message: String; var body: some View { ContentUnavailableView(title, systemImage: icon, description: Text(message)).frame(maxWidth: .infinity, maxHeight: .infinity) } }
