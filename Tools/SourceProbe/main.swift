import Foundation
import MangaCore
import MangaPlatform
#if os(macOS)
import AppKit
#endif
actor DiagnosticTransport: ScopedHTTPTransport {
    let transport = URLSessionTransport()
    var responses: [[String: String]] = []
    func load(_ request: URLRequest) async throws -> ResourceResponse {
        do {
            let response = try await transport.load(request)
            responses.append(["host": response.finalURL.host ?? "", "status": String(response.statusCode)])
            return response
        } catch { responses.append(["host": request.url?.host ?? "", "error": String(describing: (error as? URLError)?.code.rawValue ?? -1)]); throw error }
    }
    func load(_ request: URLRequest, sourceID: SourceID, contextID: UUID?, contexts: AccessContextStore) async throws -> ResourceResponse {
        do { let response = try await transport.load(request, sourceID: sourceID, contextID: contextID, contexts: contexts); responses.append(["host": response.finalURL.host ?? "", "status": String(response.statusCode)]); return response }
        catch { responses.append(["host": request.url?.host ?? "", "error": String(describing: (error as? URLError)?.code.rawValue ?? -1)]); throw error }
    }

}
func argument(_ name: String) -> String? { guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }; return CommandLine.arguments[index + 1] }
guard CommandLine.arguments.contains("--online"), let sourceName = argument("--source"), let urlString = argument("--work-url"), let workURL = URL(string: urlString) else {
    print("Usage: swift run SourceProbe --source guazi|dm5|manhuazhan|mangadex|xkcd|baozi --work-url URL --online"); exit(2)
}
let index = ["manhuazhan": 0, "guazi": 1, "dm5": 2, "mangadex": 3, "xkcd": 4, "baozi": 5][sourceName] ?? -1
guard index >= 0 else { print("Unknown source"); exit(2) }
let source = BuiltinSources.candidates()[index]
guard let adapter = BuiltinSources.candidateAdapter(for: source) else { print("Adapter pending"); exit(2) }
let diagnostic = DiagnosticTransport(); let client = URLSessionHTTPClient(transport: diagnostic)
var renderer: (any PageRenderer)? = nil
#if os(macOS)
if ["manhuazhan", "baozi"].contains(sourceName) { _ = NSApplication.shared; renderer = WebKitRenderer(contexts: client.contexts) }
#endif
let context = ParserContext(source: source, client: client, renderer: renderer)
var report: [String: Any] = ["source": sourceName, "date": ISO8601DateFormatter().string(from: Date()), "platform": ProcessInfo.processInfo.operatingSystemVersionString, "readingVerified": false]
do { let response = try await client.send(ResourceRequest(url: source.baseURL), sourceID: source.id, priority: .probe); report["homepageStatus"] = response.statusCode } catch { report["homepageError"] = error.localizedDescription }
do { report["browseCount"] = try await adapter.browse(context: context).count } catch { report["browseError"] = error.localizedDescription }
do { report["searchCount"] = try await adapter.search(query: argument("--query") ?? "一人之下", context: context).count } catch { report["searchError"] = error.localizedDescription }
do {
    let work = try await adapter.details(url: workURL, context: context); report["detail"] = "parsed"
    let chapters = try await adapter.chapters(work: work, context: context); report["chapterCount"] = chapters.count
    let available = chapters.filter { $0.access == .available }
    guard let first = available.first else { throw MangaError.chapterUnavailable }
    let selected = available.count > 1 ? [first, available.last!] : [first]
    var outcomes: [[String: Any]] = []; var passed = true
    for chapter in selected {
        do {
            let pages = try await adapter.pages(chapter: chapter, context: context)
            var outcome: [String: Any] = ["ordinal": chapter.ordinal, "pageCount": pages.count]
            var decoded = 0
            for (imageIndex, page) in (pages.count > 1 ? [pages.first!, pages.last!] : pages).enumerated() {
                do {
                    let response = try await client.send(page.request, sourceID: source.id, priority: .probe)
                    let metadata = try ImageVerifier().verify(response.data)
                    outcome[imageIndex == 0 ? "firstImage" : "lastImage"] = ["width": metadata.width, "height": metadata.height, "format": metadata.format]
                    decoded += 1
                } catch { passed = false; outcome["imageError"] = error.localizedDescription }
            }
            if decoded == 0 { passed = false }
            outcomes.append(outcome)
        } catch { passed = false; outcomes.append(["ordinal": chapter.ordinal, "error": error.localizedDescription]) }
    }
    report["chapters"] = outcomes; report["readingVerified"] = passed && !outcomes.isEmpty
} catch { report["detailOrChapterError"] = error.localizedDescription }
report["requests"] = await diagnostic.responses
let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: output, as: UTF8.self))
exit(report["readingVerified"] as? Bool == true ? 0 : 1)
