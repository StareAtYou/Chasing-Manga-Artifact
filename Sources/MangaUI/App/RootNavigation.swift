import SwiftUI
import MangaCore
public struct RootNavigation<ReaderContent: View>: View {
    @Bindable private var app: AppContainer
    private let readerDestination: (ChapterID) -> ReaderContent
    public init(container: AppContainer, @ViewBuilder readerDestination: @escaping (ChapterID) -> ReaderContent) { app = container; self.readerDestination = readerDestination }
    public var body: some View {
        Group {
            #if os(macOS)
            NavigationSplitView {
                List(AppSection.allCases, selection: Binding<AppSection?>(get: { app.section }, set: { if let value = $0 { app.section = value } })) { section in Label(section.title, systemImage: section.icon).tag(section) }
                    .navigationTitle("追漫").navigationSplitViewColumnWidth(min: 180, ideal: 210)
            } detail: { stack(app.section) }
            #else
            TabView(selection: $app.section) { ForEach(AppSection.allCases) { section in stack(section).tabItem { Label(section.title, systemImage: section.icon) }.tag(section) } }
            #endif
        }
        .environment(app).tint(.teal).onChange(of: app.section) { _, _ in app.path = [] }
        .preferredColorScheme(app.settings.theme == .system ? nil : (app.settings.theme == .dark ? .dark : .light))
        .task { await app.start() }
        .alert("操作未完成", isPresented: Binding(get: { app.message != nil }, set: { if !$0 { app.message = nil } })) { Button("好", role: .cancel) { app.message = nil } } message: { Text(app.message ?? "") }
    }
    private func stack(_ section: AppSection) -> some View {
        NavigationStack(path: Binding(get: { section == app.section ? app.path : [] }, set: { if section == app.section { app.path = $0 } })) {
            sectionView(section).navigationDestination(for: Route.self) { route in
                switch route { case .work(let id): WorkDetailView(workID: id).id(id); case .chapters(let id): ChapterListView(sourceWorkID: id).id(id); case .reader(let id): readerDestination(id).id(id) }
            }
        }
    }
    @ViewBuilder private func sectionView(_ section: AppSection) -> some View { switch section { case .library: LibraryView(); case .discovery: DiscoveryView(); case .updates: UpdatesView(); case .downloads: DownloadsView() } }
}
