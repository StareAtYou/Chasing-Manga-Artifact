import Foundation
public enum SearchScope: Hashable, Sendable {
    case all
    case source(SourceID)
    case excluding(Set<SourceID>)
    public static func searchableSources(in sources: [Source]) -> [Source] {
        sources.filter { source in
            guard source.enabled, !source.removed else { return false }
            if source.capabilities.contains(.search) { return true }
            // A startup probe may fail because the site requires verification.
            // Declared built-in search support remains available for an explicit retry.
            guard BuiltinSources.candidates().contains(where: { $0.id == source.id }),
                  let adapter = BuiltinSources.candidateAdapter(for: source), adapter.capabilities.contains(.search) else { return false }
            guard let binding = source.binding else { return true }
            return !binding.needsRetest && binding.parserID == adapter.id && binding.version == adapter.version
        }
    }
    public func sourceIDs(in sources: [Source]) -> [SourceID] {
        let available = Self.searchableSources(in: sources)
        switch self {
        case .all: return available.map(\.id)
        case .source(let id): return available.filter { $0.id == id }.map(\.id)
        case .excluding(let excluded): return available.filter { !excluded.contains($0.id) }.map(\.id)
        }
    }
}
public enum SearchEvent: Sendable {
    case results(queryID: UUID, sourceID: SourceID, works: [SourceWork])
    case failure(queryID: UUID, sourceID: SourceID, error: MangaError)
    case finished(queryID: UUID)
    public var queryID: UUID { switch self { case .results(let id, _, _), .failure(let id, _, _), .finished(let id): id } }
}
public actor SearchService {
    private let store: LibraryStore
    private let sources: SourceService
    private var job: Task<Void, Never>?
    private var generation = UUID()
    public init(store: LibraryStore, sources: SourceService) { self.store = store; self.sources = sources }
    public func search(query: String, sourceIDs: [SourceID], queryID: UUID) -> AsyncStream<SearchEvent> {
        job?.cancel(); let generation = UUID(); self.generation = generation
        let (stream, continuation) = AsyncStream<SearchEvent>.makeStream()
        let sources = self.sources; let store = self.store
        let task = Task {
            let available = (try? await store.sources()) ?? []
            await withTaskGroup(of: SearchEvent.self) { group in
                for source in SearchScope.searchableSources(in: available) where sourceIDs.contains(source.id) {
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let adapter = try await sources.adapter(for: source.id)
                            let context = try await sources.context(for: source.id)
                            let works = try await adapter.search(query: query, context: context)
                            try Task.checkCancellation()
                            return .results(queryID: queryID, sourceID: source.id, works: works.filter { $0.id.sourceID == source.id })
                        } catch let error as MangaError { return .failure(queryID: queryID, sourceID: source.id, error: error) }
                        catch { return .failure(queryID: queryID, sourceID: source.id, error: .networkUnavailable) }
                    }
                }
                for await event in group {
                    guard !Task.isCancelled, self.generation == generation else { group.cancelAll(); break }
                    continuation.yield(event)
                }
            }
            if !Task.isCancelled, self.generation == generation { continuation.yield(.finished(queryID: queryID)) }
            continuation.finish()
        }
        job = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
    public func cancel() { job?.cancel(); generation = UUID() }
}
