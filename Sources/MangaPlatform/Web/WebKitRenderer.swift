import Foundation
import MangaCore
@MainActor public final class WebKitRenderer: PageRenderer {
    private let contexts: AccessContextStore
    private var sessions: [SourceID: WebAccessSession] = [:]
    public init(contexts: AccessContextStore) { self.contexts = contexts }
    public func session(for source: Source) -> WebAccessSession {
        if let session = sessions[source.id], session.source.baseURL == source.baseURL { return session }
        let session = WebAccessSession(source: source, contexts: contexts); sessions[source.id] = session; return session
    }
    public func render(url: URL, source: Source, interactive: Bool) async throws -> RenderedPage { try await session(for: source).render(url: url, interactive: interactive) }
    public func remove(sourceID: SourceID) async { sessions.removeValue(forKey: sourceID)?.cancel(); await contexts.remove(sourceID: sourceID) }
}
