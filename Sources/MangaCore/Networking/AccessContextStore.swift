import Foundation
public struct WebOrigin: Hashable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int
    public init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host?.lowercased() else { return nil }
        self.scheme = scheme; self.host = host; port = url.port ?? (scheme == "https" ? 443 : 80)
    }
}
public struct ScopedCookie: Sendable, Hashable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let secure: Bool
    public let expires: Date?
    public let hostOnly: Bool
    public init(name: String, value: String, domain: String, path: String = "/", secure: Bool = false, expires: Date? = nil, hostOnly: Bool = true) { self.name = name; self.value = value; self.domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")); self.path = path.isEmpty ? "/" : path; self.secure = secure; self.expires = expires; self.hostOnly = hostOnly }
    public func matches(_ url: URL, now: Date) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let requestPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"
        let domainMatches = host == domain || (!hostOnly && host.hasSuffix("." + domain))
        let pathMatches = requestPath == path || (requestPath.hasPrefix(path) && (path.hasSuffix("/") || requestPath.dropFirst(path.count).first == "/"))
        return domainMatches && pathMatches && (!secure || url.scheme?.lowercased() == "https") && (expires.map { $0 > now } ?? true)
    }
}
public actor AccessContextStore {
    private struct Context: Sendable {
        let sourceID: SourceID
        let origin: WebOrigin
        let headers: [String: String]
        let cookies: [ScopedCookie]
    }
    private var latest: [SourceID: UUID] = [:]
    private var contexts: [UUID: Context] = [:]
    public init() { }
    public func register(sourceID: SourceID, originURL: URL, headers: [String: String] = [:], cookies: [ScopedCookie] = []) throws -> UUID {
        guard let origin = WebOrigin(originURL) else { throw MangaError.invalidURL }
        let id = UUID(); contexts[id] = Context(sourceID: sourceID, origin: origin, headers: headers, cookies: cookies); latest[sourceID] = id; return id
    }
    public func headers(for id: UUID?, sourceID: SourceID, url: URL, now: Date = Date()) -> [String: String] {
        guard let id = id ?? latest[sourceID], let context = contexts[id], context.sourceID == sourceID, WebOrigin(url) == context.origin else { return [:] }
        var headers = context.headers
        if !context.cookies.isEmpty {
            for key in headers.keys where key.lowercased() == "cookie" { headers.removeValue(forKey: key) }
            let cookies = context.cookies.filter { $0.matches(url, now: now) }.sorted { $0.path.count > $1.path.count }
            if !cookies.isEmpty { headers["Cookie"] = cookies.map { $0.name + "=" + $0.value }.joined(separator: "; ") }
        }
        return headers
    }
    public func redirected(_ request: URLRequest, from originURL: URL, sourceID: SourceID, contextID: UUID?, now: Date = Date()) -> URLRequest {
        var safe = RedirectPolicy.sanitize(request, from: originURL)
        safe.setValue(nil, forHTTPHeaderField: "Cookie")
        if let url = safe.url { for (key, value) in headers(for: contextID, sourceID: sourceID, url: url, now: now) { safe.setValue(value, forHTTPHeaderField: key) } }
        return safe
    }
    public func remove(sourceID: SourceID) { latest.removeValue(forKey: sourceID); contexts = contexts.filter { $0.value.sourceID != sourceID } }
}
