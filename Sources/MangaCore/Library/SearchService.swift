import Foundation
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
                for source in available where sourceIDs.contains(source.id) && source.enabled && source.capabilities.contains(.search) {
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
