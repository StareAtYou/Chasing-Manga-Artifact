import SwiftUI
import MangaUI
@main struct MangaMacApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var container: AppContainer?
    private let startupError: String?
    init() { do { _container = State(initialValue: try AppContainer()); startupError = nil } catch { _container = State(initialValue: nil); startupError = error.localizedDescription } }
    var body: some Scene {
        WindowGroup {
            if let container { RootNavigation(container: container) { ReaderView(container: container, chapterID: $0) }.frame(minWidth: 800, minHeight: 600) }
            else { ContentUnavailableView("无法读取本地资料", systemImage: "externaldrive.badge.exclamationmark", description: Text(startupError ?? "请重新启动")) }
        }.defaultSize(width: 1100, height: 800).onChange(of: scenePhase) { _, phase in if phase == .active { container?.updateScheduler.onAppActive() } }
    }
}
