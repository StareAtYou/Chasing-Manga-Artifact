import Foundation
import MangaCore
private struct TransferIdentity: Codable, Sendable {
    let taskID: UUID
    let pageKey: String
    let destination: URL
    var key: String { taskID.uuidString + ":" + pageKey }
}
private struct TransferCompletion: Codable {
    let identity: TransferIdentity
    let file: URL
    let statusCode: Int
    let bytes: Int
}
private actor TransferWaiters {
    struct Waiter { let destination: URL; let continuation: CheckedContinuation<TransferResult, Error> }
    var waiting: [String: Waiter] = [:]
    var completed: [String: Result<TransferResult, Error>] = [:]
    func wait(_ identity: TransferIdentity, nativeID: Int) async throws -> TransferResult {
        let key = identity.key + ":" + String(nativeID)
        return try await withCheckedThrowingContinuation { continuation in
            if let result = completed.removeValue(forKey: key) { continuation.resume(with: result); return }
            if let old = waiting.removeValue(forKey: key) { old.continuation.resume(throwing: CancellationError()) }
            waiting[key] = Waiter(destination: identity.destination, continuation: continuation)
        }
    }
    func finish(_ identity: TransferIdentity, nativeID: Int, result: Result<TransferResult, Error>) {
        let key = identity.key + ":" + String(nativeID)
        guard let waiter = waiting.removeValue(forKey: key) else { completed[key] = result; return }
        do {
            var value = try result.get()
            if value.file != waiter.destination {
                if FileManager.default.fileExists(atPath: waiter.destination.path) { try FileManager.default.removeItem(at: waiter.destination) }
                try FileManager.default.moveItem(at: value.file, to: waiter.destination)
                value = TransferResult(file: waiter.destination, statusCode: value.statusCode, bytes: value.bytes)
            }
            waiter.continuation.resume(returning: value)
        } catch { waiter.continuation.resume(throwing: error) }
    }
    func cancel(_ key: String) { waiting.removeValue(forKey: key)?.continuation.resume(throwing: CancellationError()) }
}
// session is assigned once during initialization. Mutable completion state belongs to an actor.
public final class BackgroundTransfer: NSObject, PageTransferring, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let identifier = "com.chasingmanga.local.download"
    private var session: URLSession!
    private let waiters = TransferWaiters()
    private let contexts: AccessContextStore
    private let scheduler: RequestScheduler
    private let recoveryDirectory: URL
    private let foreground: URLSessionHTTPClient
    private let finishEvents: @Sendable () -> Void
    public init(root: URL, contexts: AccessContextStore, scheduler: RequestScheduler, finishEvents: @escaping @Sendable () -> Void = {}) throws {
        self.contexts = contexts; self.scheduler = scheduler; self.finishEvents = finishEvents
        foreground = URLSessionHTTPClient(scheduler: scheduler, contexts: contexts)
        recoveryDirectory = root.appendingPathComponent("transfers", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.isDiscretionary = false; configuration.httpMaximumConnectionsPerHost = 2
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 120
        #if os(iOS)
        configuration.sessionSendsLaunchEvents = true
        #endif
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    public func download(_ resource: ResourceRequest, sourceID: SourceID, taskID: UUID, to: URL) async throws -> TransferResult {
        let scoped = await contexts.headers(for: resource.accessContextID, sourceID: sourceID, url: resource.url)
        let publicHeaders = Set(["accept", "accept-language", "accept-encoding", "user-agent", "referer", "content-type", "x-requested-with"])
        let credentialed = resource.body != nil || resource.method == .post || !scoped.isEmpty || resource.headers.keys.contains { !publicHeaders.contains($0.lowercased()) }
        // Foundation background sessions always follow redirects and skip the redirect delegate.
        // Credentialed requests use the controlled foreground transport instead.
        if credentialed {
            let response = try await foreground.send(resource, sourceID: sourceID, priority: .download)
            try Task.checkCancellation(); try response.data.write(to: to, options: .atomic)
            return TransferResult(file: to, statusCode: response.statusCode, bytes: response.data.count)
        }
        let pageKey = to.lastPathComponent.components(separatedBy: ".partial.")[0]
        let identity = TransferIdentity(taskID: taskID, pageKey: pageKey, destination: to)
        if let cached = try takeCompletion(identity) { return cached }
        let lease = try await scheduler.acquire(sourceID: sourceID, priority: .download)
        do {
            try Task.checkCancellation()
            var request = URLRequest(url: resource.url)
            request.allHTTPHeaderFields = resource.headers; request.httpMethod = resource.method?.rawValue ?? "GET"; request.httpBody = resource.body
            if let referer = resource.referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
            for (key, value) in await contexts.headers(for: resource.accessContextID, sourceID: sourceID, url: resource.url) { request.setValue(value, forHTTPHeaderField: key) }
            let tasks = await session.allTasks
            let existing = tasks.first { task in Self.identity(task)?.key == identity.key }
            let native = existing ?? session.downloadTask(with: request)
            if existing == nil { native.taskDescription = String(decoding: try JSONEncoder().encode(identity), as: UTF8.self) }
            let result = try await withTaskCancellationHandler {
                native.resume()
                return try await waiters.wait(identity, nativeID: native.taskIdentifier)
            } onCancel: {
                native.cancel(); Task { await self.waiters.cancel(identity.key + ":" + String(native.taskIdentifier)) }
            }
            removeCompletion(identity, file: result.file)
            await scheduler.release(lease); return result
        } catch { await scheduler.release(lease); throw error }
    }
    private func completionURL(_ identity: TransferIdentity, nativeID: Int) -> URL {
        recoveryDirectory.appendingPathComponent(ContentDigest.hex(Data((identity.key + ":" + String(nativeID)).utf8)) + ".json")
    }
    private func completionFiles() -> [(URL, TransferCompletion)] {
        ((try? FileManager.default.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(TransferCompletion.self, from: data), value.file.deletingLastPathComponent().standardizedFileURL == recoveryDirectory.standardizedFileURL else { return nil }
            return (url, value)
        }
    }
    private func takeCompletion(_ identity: TransferIdentity) throws -> TransferResult? {
        for (marker, value) in completionFiles() where value.identity.key == identity.key {
            guard (200..<300).contains(value.statusCode), FileManager.default.fileExists(atPath: value.file.path) else { try? FileManager.default.removeItem(at: marker); continue }
            if FileManager.default.fileExists(atPath: identity.destination.path) { try FileManager.default.removeItem(at: identity.destination) }
            try FileManager.default.moveItem(at: value.file, to: identity.destination)
            try FileManager.default.removeItem(at: marker)
            return TransferResult(file: identity.destination, statusCode: value.statusCode, bytes: value.bytes)
        }
        return nil
    }
    private func removeCompletion(_ identity: TransferIdentity, file: URL) {
        for (marker, value) in completionFiles() where value.identity.key == identity.key && (value.file == file || !FileManager.default.fileExists(atPath: value.file.path)) { try? FileManager.default.removeItem(at: marker) }
    }
    private static func identity(_ task: URLSessionTask) -> TransferIdentity? {
        guard let description = task.taskDescription else { return nil }
        return try? JSONDecoder().decode(TransferIdentity.self, from: Data(description.utf8))
    }
    public func recoverTransfers() async throws -> [TransferRecord] {
        let active = await session.allTasks.compactMap { task in Self.identity(task).map { TransferRecord(taskID: $0.taskID, state: task.state == .suspended ? .paused : .running) } }
        return active + completionFiles().map { TransferRecord(taskID: $0.1.identity.taskID, state: .completed) }
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let identity = Self.identity(downloadTask) else { return }
        do {
            let retained = recoveryDirectory.appendingPathComponent(UUID().uuidString + ".image")
            try FileManager.default.moveItem(at: location, to: retained)
            let bytes = (try retained.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            let completion = TransferCompletion(identity: identity, file: retained, statusCode: status, bytes: bytes)
            try JSONEncoder().encode(completion).write(to: completionURL(identity, nativeID: downloadTask.taskIdentifier), options: .atomic)
            let result = TransferResult(file: retained, statusCode: status, bytes: bytes)
            Task { await waiters.finish(identity, nativeID: downloadTask.taskIdentifier, result: .success(result)) }
        } catch { Task { await waiters.finish(identity, nativeID: downloadTask.taskIdentifier, result: .failure(error)) } }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let identity = Self.identity(task) else { return }
        let mapped: Error
        if let url = error as? URLError { mapped = url.code == .cancelled ? CancellationError() as Error : NetworkErrorMapper.map(url) as Error }
        else if (error as? CocoaError)?.code == .fileWriteOutOfSpace { mapped = MangaError.diskFull }
        else { mapped = error }
        Task { await waiters.finish(identity, nativeID: task.taskIdentifier, result: .failure(mapped)) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let original = response.url else { completionHandler(nil); return }
        completionHandler(RedirectPolicy.sanitize(request, from: original))
    }
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) { finishEvents() }
}
