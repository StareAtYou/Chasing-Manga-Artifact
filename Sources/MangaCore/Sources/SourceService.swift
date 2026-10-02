import Foundation
public actor SourceService {
    public let store: LibraryStore
    private let registry: ParserRegistry
    private let client: any HTTPClient
    private let verifier: any ImageVerifying
    private let renderer: (any PageRenderer)?
    private var generations: [SourceID: UUID] = [:]
    public init(store: LibraryStore, registry: ParserRegistry, client: any HTTPClient, verifier: any ImageVerifying, renderer: (any PageRenderer)? = nil) {
        self.store = store; self.registry = registry; self.client = client; self.verifier = verifier; self.renderer = renderer
    }
    public func add(name: String, baseURL: URL, samples: [URL]) async throws -> DetectionReport {
        let source = Source(name: name.isEmpty ? (baseURL.host ?? "漫画源") : name, baseURL: try canonicalSourceURL(baseURL))
        try await store.save(source: source)
        return try await retest(sourceID: source.id, samples: samples)
    }
    public func retest(sourceID: SourceID, samples: [URL]) async throws -> DetectionReport {
        let source = try await activeSource(sourceID)
        let generation = try await store.beginDetection(sourceID: sourceID); generations[sourceID] = generation
        var report = await SourceDetector(registry: registry, client: client, verifier: verifier, renderer: renderer).detect(source: source, samples: samples)
        report.detectionID = generation
        try Task.checkCancellation()
        guard generations[sourceID] == generation else { throw CancellationError() }
        if let binding = report.binding { try await commit(binding, report: report, candidate: report.candidates.first!) }
        return report
    }
    public func choose(parserID: String, from report: DetectionReport) async throws {
        guard report.status == .ambiguous, let candidate = report.candidates.first(where: { $0.id == parserID }) else { throw MangaError.parseMismatch("候选已失效") }
        try await commit(candidate.binding, report: report, candidate: candidate)
    }
    private func commit(_ binding: ParserBinding, report: DetectionReport, candidate: DetectionCandidate) async throws {
        try Task.checkCancellation()
        guard try await store.commitDetection(binding: binding, sourceID: report.sourceID, expectedRevision: report.sourceRevision, works: candidate.works, generation: report.detectionID) else { throw MangaError.parseMismatch("来源地址已经改变，请重新检测") }
    }
    private func activeSource(_ id: SourceID) async throws -> Source {
        guard let source = try await store.source(id: id), source.enabled, !source.removed else { throw MangaError.unsupported("来源已停用或删除") }
        return source
    }
    public func context(for sourceID: SourceID) async throws -> ParserContext { ParserContext(source: try await activeSource(sourceID), client: client, renderer: renderer) }
    public func adapter(for sourceID: SourceID) async throws -> any SourceAdapter {
        let source = try await activeSource(sourceID)
        if source.binding == nil, BuiltinSources.candidates().contains(where: { $0.id == sourceID }), let adapter = BuiltinSources.candidateAdapter(for: source) { return adapter }
        let adapter = try registry.adapter(for: source)
        if source.binding?.version != adapter.version {
            let urls = try await store.allSourceWorks().filter { $0.id.sourceID == sourceID }.map(\.url)
            let report = try await retest(sourceID: sourceID, samples: Array(urls.prefix(1)))
            guard report.binding != nil else { throw MangaError.parseMismatch("解析方式已更新，请重新检测") }
        }
        return adapter
    }
    public func inspectCatalogCapabilities(sourceID: SourceID, searchQuery: String) async throws -> [String: MangaError] {
        let source = try await activeSource(sourceID)
        let adapter = try await adapter(for: sourceID); let context = try await context(for: sourceID)
        var capabilities = source.capabilities; var errors: [String: MangaError] = [:]
        do { if !(try await adapter.browse(context: context)).isEmpty { capabilities.insert(.browse) } }
        catch { errors["browse"] = (error as? MangaError) ?? .networkUnavailable }
        do { if !(try await adapter.search(query: searchQuery, context: context)).isEmpty { capabilities.insert(.search) } }
        catch { errors["search"] = (error as? MangaError) ?? .networkUnavailable }
        guard var latest = try await store.source(id: sourceID), latest.revision == source.revision, !latest.removed else { throw CancellationError() }
        latest.capabilities = capabilities; try await store.save(source: latest)
        return errors
    }
    public func setEnabled(_ enabled: Bool, sourceID: SourceID) async throws {
        guard var source = try await store.source(id: sourceID), !source.removed else { throw MangaError.unsupported("来源不存在") }
        source.enabled = enabled; try await store.save(source: source)
        if !enabled { generations[sourceID] = UUID() }
    }
    public func remove(sourceID: SourceID) async throws { generations[sourceID] = UUID(); try await store.remove(sourceID: sourceID) }
    public func recordResult(sourceID: SourceID, error: MangaError?) async throws {
        guard let source = try await store.source(id: sourceID), var binding = source.binding else { return }
        if let error {
            guard case .parseMismatch = error else { return }
            binding.structureFailures += 1; binding.needsRetest = binding.structureFailures >= 2
        } else { binding.structureFailures = 0 }
        _ = try await store.save(binding: binding, sourceID: sourceID, expectedRevision: source.revision)
    }
    public func details(url: URL, sourceID: SourceID) async throws -> SourceWork {
        try await tracked(sourceID) { adapter, context in try await adapter.details(url: url, context: context) }
    }
    public func chapters(work: SourceWork) async throws -> [Chapter] {
        try await tracked(work.id.sourceID) { adapter, context in try await adapter.chapters(work: work, context: context) }
    }
    public func pages(chapter: Chapter) async throws -> [PageResource] {
        try await tracked(chapter.id.sourceWorkID.sourceID) { adapter, context in try await adapter.pages(chapter: chapter, context: context) }
    }
    private func tracked<T: Sendable>(_ sourceID: SourceID, operation: @Sendable (any SourceAdapter, ParserContext) async throws -> T) async throws -> T {
        do {
            let result = try await operation(adapter(for: sourceID), context(for: sourceID))
            try await recordResult(sourceID: sourceID, error: nil); return result
        } catch let error as MangaError { try await recordResult(sourceID: sourceID, error: error); throw error }
    }
}
