import Foundation
import Network
import MangaCore
import MangaPlatform

/// A real local HTTP endpoint: the first attempt is throttled, the next returns
/// an image. This catches public images bypassing the foreground retry client.
private final class RetryImageServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "manga.transfer-test.server")
    private var attempts = 0
    private var stalled: [NWConnection] = []
    private let image: Data
    private let stallFirst: Bool
    init(image: Data, stallFirst: Bool = false) throws { self.image = image; self.stallFirst = stallFirst; listener = try NWListener(using: .tcp, on: .any) }
    func hasRequest() async -> Bool { await withCheckedContinuation { c in queue.async { c.resume(returning: self.attempts > 0) } } }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                if case .ready = state { continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/image.png")!) }
                else if case .failed(let error) = state { continuation.resume(throwing: error) }
            }
            listener.newConnectionHandler = { [self] connection in connection.start(queue: queue); receive(connection, prefix: Data()) }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection, prefix: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            var input = prefix; input.append(data ?? Data())
            guard input.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if error == nil && !complete { receive(connection, prefix: input) } else { connection.cancel() }
                return
            }
            attempts += 1
            if attempts == 1 && stallFirst { stalled.append(connection); return }
            let throttled = attempts == 1
            let body = throttled ? Data("retry".utf8) : image
            var response = Data("HTTP/1.1 \(throttled ? "429 Too Many Requests" : "200 OK")\r\nRetry-After: 0\r\nContent-Type: image/png\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    func stop() { listener.cancel(); queue.async { self.stalled.forEach { $0.cancel() }; self.stalled.removeAll() } }
}

private actor TransferActivity {
    var active = true
    func enterBackground() { active = false }
    func enterForeground() { active = true }
}
public let backgroundThroughputChecks: [Check] = [
    Check("BackgroundThroughputTests.activePublicImagesUseRetryingForegroundTransport") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let image = try generatedPNG(); let server = try RetryImageServer(image: image)
        let url = try await server.start(); defer { server.stop() }
        let activity = TransferActivity()
        let transfer = try BackgroundTransfer(root: root, contexts: AccessContextStore(), scheduler: RequestScheduler(), isForeground: { await activity.active })
        let destination = root.appendingPathComponent("image.png")
        let result = try await transfer.download(ResourceRequest(url: url), sourceID: Samples.sourceA.id, taskID: UUID(), to: destination)
        try expect(result.statusCode == 200, "Active public-image transfers must respect Retry-After and retry before reporting completion")
        try expect(result.file == destination && result.bytes == image.count && (try Data(contentsOf: destination)) == image, "Foreground delivery must preserve the requested file and bytes")

        // A subsequent request must consult activity again, rather than freezing
        // the route chosen when the session was initialized.
        await activity.enterBackground()
        let backgroundServer = try RetryImageServer(image: image)
        let backgroundURL = try await backgroundServer.start(); defer { backgroundServer.stop() }
        let background = try await transfer.download(ResourceRequest(url: backgroundURL), sourceID: Samples.sourceA.id, taskID: UUID(), to: root.appendingPathComponent("background.png"))
        try expect(background.statusCode == 429, "Inactive public requests still use the system background transport")

        let credentialServer = try RetryImageServer(image: image)
        let credentialURL = try await credentialServer.start(); defer { credentialServer.stop() }
        let controlled = try await transfer.download(ResourceRequest(url: credentialURL, headers: ["Authorization": "test-only"]), sourceID: Samples.sourceA.id, taskID: UUID(), to: root.appendingPathComponent("controlled.png"))
        try expect(controlled.statusCode == 200 && controlled.bytes == image.count, "Credentials must retain controlled redirects and retry behavior even while inactive")

        await activity.enterForeground()
        let handoffServer = try RetryImageServer(image: image, stallFirst: true)
        let handoffURL = try await handoffServer.start(); defer { handoffServer.stop() }
        let handoffDestination = root.appendingPathComponent("handoff.png")
        let handoff = Task { try await transfer.download(ResourceRequest(url: handoffURL), sourceID: Samples.sourceA.id, taskID: UUID(), to: handoffDestination) }
        for _ in 0..<100 { if await handoffServer.hasRequest() { break }; try await Task.sleep(for: .milliseconds(10)) }
        await activity.enterBackground()
        let handedOff = try await handoff.value
        try expect(handedOff.statusCode == 200 && (try Data(contentsOf: handoffDestination)) == image, "An in-flight foreground request must move to native background delivery without waiting for foreground resumption")

        await activity.enterForeground()
        let cancelServer = try RetryImageServer(image: image, stallFirst: true)
        let cancelURL = try await cancelServer.start(); defer { cancelServer.stop() }
        let cancelled = Task { try await transfer.download(ResourceRequest(url: cancelURL), sourceID: Samples.sourceA.id, taskID: UUID(), to: root.appendingPathComponent("cancelled.png")) }
        for _ in 0..<100 { if await cancelServer.hasRequest() { break }; try await Task.sleep(for: .milliseconds(10)) }
        cancelled.cancel(); await activity.enterBackground()
        do { _ = try await cancelled.value; throw CheckFailure(description: "Cancellation must win over background handoff") } catch is CancellationError { }
    }
]
