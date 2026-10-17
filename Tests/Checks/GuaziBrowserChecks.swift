import Foundation
import Network
import MangaCore
import MangaPlatform
#if os(macOS)
import AppKit
#endif
private final class SlowImageDocumentServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "manga.dom-test.server")
    private var pending: [NWConnection] = []
    private let image: Data
    init() throws { listener = try NWListener(using: .tcp, on: .any); image = try generatedPNG() }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                if case .ready = state { continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")!) }
                else if case .failed(let error) = state { continuation.resume(throwing: error) }
            }
            listener.newConnectionHandler = { [self] connection in connection.start(queue: queue); read(connection, input: Data()) }
            listener.start(queue: queue)
        }
    }
    private func read(_ connection: NWConnection, input: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            var request = input; request.append(data ?? Data())
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if error == nil && !complete { read(connection, input: request) } else { connection.cancel() }; return
            }
            if String(decoding: request, as: UTF8.self).hasPrefix("GET /chapter.php") {
                let html = "<html><head><title>Reader</title></head><body><img class='reading-image' src='/slow1.png'><img class='reading-image' src='/slow2.png'></body></html>"
                send(Data(html.utf8), type: "text/html", to: connection)
            } else { pending.append(connection) }
        }
    }
    private func send(_ body: Data, type: String, to connection: NWConnection) {
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8); response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
    func hasBlockedImages() async -> Bool { await withCheckedContinuation { c in queue.async { c.resume(returning: !self.pending.isEmpty) } } }
    func releaseImages() { queue.async { let connections = self.pending; self.pending.removeAll(); for connection in connections { self.send(self.image, type: "image/png", to: connection) } } }
    func stop() { listener.cancel(); queue.async { self.pending.forEach { $0.cancel() }; self.pending.removeAll() } }
}
public let guaziBrowserChecks: [Check] = [
    Check("GuaziBrowserTests.completeDOMDoesNotWaitForSlowImageAssets") { @MainActor in
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        let server = try SlowImageDocumentServer(); let base = try await server.start(); defer { server.stop() }
        let source = Source(name: "Reader fixture", baseURL: base, binding: ParserBinding(parserID: "guazi-html"))
        let session = WebAccessSession(source: source, contexts: AccessContextStore())
        var completed = false
        let rendering = Task { @MainActor in let page = try await session.render(url: base.appendingPathComponent("chapter.php"), interactive: false); completed = true; return page }
        for _ in 0..<500 { if await server.hasBlockedImages() { break }; try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<200 { if completed { break }; try await Task.sleep(for: .milliseconds(10)) }
        let capturedBeforeImages = completed
        server.releaseImages()
        let page = try await rendering.value
        try expect(capturedBeforeImages && page.html.contains("slow1.png") && page.html.contains("slow2.png"), "A complete reader DOM must be captured before slow image assets finish, without truncating the list")
    }
]
