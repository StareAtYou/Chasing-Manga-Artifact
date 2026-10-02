import SwiftUI
import MangaCore
struct ReaderToolbar: ToolbarContent {
    let model: ReaderModel
    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button { model.navigate(-1) } label: { Label("上一章", systemImage: "backward.end") }.disabled(model.directory.first?.id == model.chapterID)
            Menu { ForEach(model.directory) { chapter in Button(chapter.title) { if !model.app.path.isEmpty { model.app.path.removeLast() }; model.app.path.append(.reader(chapter.id)) } } } label: { Label("章节目录", systemImage: "list.bullet") }
            Button { model.navigate(1) } label: { Label("下一章", systemImage: "forward.end") }.disabled(model.directory.last?.id == model.chapterID)
            Menu {
                Button("纵向滚动") { Task { await model.mode(.scroll) } }; Button("逐页阅读") { Task { await model.mode(.paged) } }
                #if os(macOS)
                Button("双页阅读") { Task { await model.mode(.doublePage) } }
                #endif
                Divider(); Button("从左向右") { Task { await model.direction(.leftToRight) } }; Button("从右向左") { Task { await model.direction(.rightToLeft) } }
                Divider(); Button("跟随系统背景") { Task { await model.background(.system) } }; Button("浅色背景") { Task { await model.background(.light) } }; Button("深色背景") { Task { await model.background(.dark) } }
            } label: { Label("阅读设置", systemImage: "text.book.closed") }.accessibilityIdentifier("reader-settings")
        }
    }
}
