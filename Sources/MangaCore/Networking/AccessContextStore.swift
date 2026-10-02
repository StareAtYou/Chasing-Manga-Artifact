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

public actor AccessContextStore {
    private struct Context: Sendable {
        let sourceID: SourceID
        let origin: WebOrigin
        let headers: [String: String]
    }
    private var contexts: [UUID: Context] = [:]
    public init() { }
    public func register(sourceID: SourceID, originURL: URL, headers: [String: String]) throws -> UUID {
        guard let origin = WebOrigin(originURL) else { throw MangaError.invalidURL }
        let id = UUID(); contexts[id] = Context(sourceID: sourceID, origin: origin, headers: headers); return id
    }
    public func headers(for id: UUID?, sourceID: SourceID, url: URL) -> [String: String] {
        guard let id, let context = contexts[id], context.sourceID == sourceID, WebOrigin(url) == context.origin else { return [:] }
        return context.headers
    }
    public func remove(sourceID: SourceID) { contexts = contexts.filter { $0.value.sourceID != sourceID } }
}
