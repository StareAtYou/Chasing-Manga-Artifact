import SwiftUI
import Foundation
import CoreGraphics
import ImageIO
import MangaCore
import MangaPlatform
// Original, locally generated test content. Production app entry points only select this
// graph in DEBUG builds with the explicit --ui-testing launch argument.
@MainActor public enum UITestBootstrap {
    public static func make(root: URL) async throws -> AppContainer {
        var template = HTMLTemplate(); template.searchPath = "/search?q={query}"
        let client = try LocalComicClient()
        let app = try AppContainer(root: root, client: client, registry: ParserRegistry(adapters: [HTMLTemplateAdapter(template: template)]), transfer: LocalComicTransfer(data: client.image), notifications: SilentNotifications())
        for (index, host) in ["first.fixture.invalid", "second.fixture.invalid"].enumerated() {
            let source = Source(id: SourceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000090\(index)")!), name: "本地样本源 \(index + 1)", baseURL: URL(string: "https://\(host)/")!, capabilities: [.browse, .search, .readable], binding: ParserBinding(parserID: "html-declared-v1"))
            try await app.store.save(source: source)
            let work = try await app.sources.details(url: source.baseURL.appendingPathComponent("work/demo"), sourceID: source.id)
            let chapters = try await app.sources.chapters(work: work)
            try await app.store.save(sourceWork: work, chapters: chapters)
            _ = try await app.store.createWork(from: work.id)
        }
        await app.start(registerBuiltins: false)
        return app
    }
}
private struct LocalComicClient: HTTPClient {
    let image: Data
    init() throws {
        guard let context = CGContext(data: nil, width: 512, height: 768, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw MangaError.invalidImage }
        context.setFillColor(CGColor(red: 0.88, green: 0.95, blue: 0.93, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 512, height: 768))
        context.setFillColor(CGColor(red: 0.08, green: 0.45, blue: 0.4, alpha: 1)); context.fill(CGRect(x: 40, y: 40, width: 432, height: 240)); context.fill(CGRect(x: 40, y: 340, width: 432, height: 380))
        let data = NSMutableData(); guard let cgImage = context.makeImage(), let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw MangaError.invalidImage }; CGImageDestinationAddImage(destination, cgImage, nil); guard CGImageDestinationFinalize(destination) else { throw MangaError.invalidImage }; image = data as Data
    }
    func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        try Task.checkCancellation()
        if request.url.path.hasSuffix(".png") { return ResourceResponse(data: image, finalURL: request.url, statusCode: 200) }
        let html: String
        if request.url.path.hasPrefix("/chapter/") { html = "<main data-manga-reader>" + (0..<4).map { "<img data-page-id='\($0)' src='/image/\($0).png'>" }.joined() + "</main>" }
        else if request.url.path.hasPrefix("/work/") {
            let slug = request.url.lastPathComponent
            let title = Self.title(slug)
            html = "<h1 data-manga-title data-work-id='\(slug)'>\(title)</h1><img data-manga-cover src='/image/cover.png'><p data-manga-summary>原创本地测试内容，用于验证分类、翻页和阅读流程。</p>" + (0..<2).map { "<a data-chapter-id='\($0)' href='/chapter/\($0)'>第\($0 + 1)话</a>" }.joined()
        } else if request.url.path.hasPrefix("/genre/") {
            let second = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "page" && $0.value == "2" } == true
            html = (second ? ["forest", "ocean"] : ["demo", "stars"]).map(Self.link).joined() + (second ? "" : "<a rel='next' href='?page=2'>下一页</a>")
        } else {
            html = "<nav><a href='/genre/adventure'>冒险</a><a href='/genre/romance'>恋爱</a></nav><section><h2>人气排行</h2>" + ["demo", "stars", "forest"].map(Self.link).joined() + "</section>"
        }
        return ResourceResponse(data: Data(html.utf8), finalURL: request.url, statusCode: 200)
    }
    static func title(_ slug: String) -> String { switch slug { case "stars": "星际来信"; case "forest": "林间日记"; case "ocean": "海边旅人"; default: "原创样本" } }
    static func link(_ slug: String) -> String { "<a data-work-id='\(slug)' href='/work/\(slug)'><img src='/image/cover.png'>\(title(slug))</a>" }
}
private struct LocalComicTransfer: PageTransferring {
    let data: Data
    func download(_ request: ResourceRequest, sourceID: SourceID, taskID: UUID, to destination: URL) async throws -> TransferResult { try Task.checkCancellation(); try data.write(to: destination, options: .atomic); return TransferResult(file: destination, statusCode: 200, bytes: data.count) }
    func recoverTransfers() async throws -> [TransferRecord] { [] }
}
private struct SilentNotifications: NotificationDelivering { func notify(workID: WorkID, chapters: [Chapter]) async throws { } }
public struct UITestLauncher: View {
    @State private var app: AppContainer?
    @State private var error: String?
    public init() { }
    public var body: some View {
        Group { if let app { RootNavigation(container: app) { ReaderView(container: app, chapterID: $0) } } else if let error { Text(error) } else { ProgressView("本地测试准备中") } }
        .task { do { let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChasingManga-UITests-" + UUID().uuidString); app = try await UITestBootstrap.make(root: root) } catch { self.error = error.localizedDescription } }
    }
}
