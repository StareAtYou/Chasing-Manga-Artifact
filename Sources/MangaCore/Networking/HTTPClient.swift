import Foundation

public protocol HTTPClient: Sendable {
    func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse
}
public protocol HTTPTransport: Sendable {
    func load(_ request: URLRequest) async throws -> ResourceResponse
}
public protocol RequestSleeper: Sendable {
    func sleep(seconds: Double) async throws
}
public struct SystemRequestSleeper: RequestSleeper {
    public init() { }
    public func sleep(seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }
}
public enum RedirectPolicy {
    public static func sanitize(_ request: URLRequest, from originURL: URL) -> URLRequest {
        guard let url = request.url, WebOrigin(url) != WebOrigin(originURL) else { return request }
        var safe = request
        safe.httpBody = nil
        if safe.httpMethod != "GET" && safe.httpMethod != "HEAD" { safe.httpMethod = "GET" }
        let allowed = Set(["accept", "accept-language", "accept-encoding", "user-agent", "referer"])
        for key in (request.allHTTPHeaderFields ?? [:]).keys where !allowed.contains(key.lowercased()) { safe.setValue(nil, forHTTPHeaderField: key) }
        return safe
    }
}
private final class SafeRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let original = response.url else { completionHandler(nil); return }
        completionHandler(RedirectPolicy.sanitize(request, from: original))
    }
}
public final class URLSessionTransport: HTTPTransport, Sendable {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.timeoutIntervalForRequest = 12
        session = URLSession(configuration: configuration, delegate: SafeRedirectDelegate(), delegateQueue: nil)
    }
    public func load(_ request: URLRequest) async throws -> ResourceResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, let url = http.url else { throw MangaError.networkUnavailable }
        let headers = Dictionary(http.allHeaderFields.map { (String(describing: $0.key), String(describing: $0.value)) }, uniquingKeysWith: { _, last in last })
        return ResourceResponse(data: data, finalURL: url, statusCode: http.statusCode, headers: headers)
    }
}
public enum NetworkErrorMapper {
    public static func map(_ error: URLError) -> MangaError {
        switch error.code {
        case .timedOut: .timedOut
        case .userAuthenticationRequired: .requiresLogin
        default: .networkUnavailable
        }
    }
}
public struct URLSessionHTTPClient: HTTPClient {
    private let transport: any HTTPTransport
    private let sleeper: any RequestSleeper
    private let scheduler: RequestScheduler
    public let contexts: AccessContextStore
    public init(transport: any HTTPTransport = URLSessionTransport(), sleeper: any RequestSleeper = SystemRequestSleeper(), scheduler: RequestScheduler = RequestScheduler(), contexts: AccessContextStore = AccessContextStore()) {
        self.transport = transport; self.sleeper = sleeper; self.scheduler = scheduler; self.contexts = contexts
    }
    public func send(_ resource: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        guard WebOrigin(resource.url) != nil, resource.url.user == nil, resource.url.password == nil else { throw MangaError.invalidURL }
        var request = URLRequest(url: resource.url, timeoutInterval: 12)
        request.httpMethod = resource.method?.rawValue ?? "GET"; request.httpBody = resource.body
        request.allHTTPHeaderFields = resource.headers
        if let referer = resource.referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        for (key, value) in await contexts.headers(for: resource.accessContextID, sourceID: sourceID, url: resource.url) { request.setValue(value, forHTTPHeaderField: key) }
        for attempt in 0...2 {
            try Task.checkCancellation()
            let lease = try await scheduler.acquire(sourceID: sourceID, priority: priority)
            let response: ResourceResponse
            do {
                try Task.checkCancellation()
                response = try await transport.load(request)
                await scheduler.release(lease)
            } catch {
                await scheduler.release(lease)
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if let error = error as? URLError { throw NetworkErrorMapper.map(error) }
                throw error
            }
            try Task.checkCancellation()
            if (200..<300).contains(response.statusCode) { return response }
            if [429, 503].contains(response.statusCode), attempt < 2 {
                let header = response.headers.first { $0.key.lowercased() == "retry-after" }?.value
                let delay = Self.retryDelay(header, fallback: Double(1 << attempt))
                try await sleeper.sleep(seconds: delay)
                continue
            }
            if response.statusCode == 401 { throw MangaError.requiresLogin }
            if response.statusCode == 404 || response.statusCode == 410 { throw MangaError.chapterUnavailable }
            throw MangaError.accessRestricted(response.statusCode)
        }
        throw MangaError.networkUnavailable
    }
    private static func retryDelay(_ header: String?, fallback: Double) -> Double {
        if let header, let seconds = Double(header), seconds.isFinite, seconds >= 0 { return min(60, seconds) }
        if let header {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: header) { return min(60, max(0, date.timeIntervalSinceNow)) }
        }
        return fallback
    }
}
