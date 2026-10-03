import Foundation
public actor SourceService {
    public let store: LibraryStore
    private let registry: ParserRegistry
    private let client: any HTTPClient
    private let verifier: any ImageVerifying
    private let renderer: (any PageRenderer)?
    private var allowedCatalogPages: [String: Set<URL>] = [:]
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
        try await inspectCatalog(sourceID: sourceID, searchQuery: searchQuery).errors
    }
    public func inspectCatalog(sourceID: SourceID, searchQuery: String? = nil) async throws -> CatalogInspection {
        let source = try await activeSource(sourceID)
        let adapter = try await adapter(for: sourceID); let context = try await context(for: sourceID)
        var capabilities = source.capabilities; var errors: [String: MangaError] = [:]; var works: [SourceWork] = []
        do {
            works = try await adapter.browse(context: context).filter { $0.id.sourceID == sourceID && SourceScope.contains($0.url, in: source.baseURL) }
            if !works.isEmpty { capabilities.insert(.browse) } else { errors["browse"] = .parseMismatch("没有取得浏览作品") }
        } catch { errors["browse"] = (error as? MangaError) ?? .networkUnavailable }
        do {
            let saved = try await store.allSourceWorks().first { $0.id.sourceID == sourceID }
            let query = searchQuery ?? works.first?.title ?? saved?.title ?? "漫画"
            let found = try await adapter.search(query: query, context: context).filter { $0.id.sourceID == sourceID && SourceScope.contains($0.url, in: source.baseURL) }
            if !found.isEmpty { capabilities.insert(.search) } else { errors["search"] = .unsupported("当前样本没有搜索结果，可换作品或稍后重试") }
        } catch { errors["search"] = (error as? MangaError) ?? .networkUnavailable }
        try Task.checkCancellation()
        guard var latest = try await store.source(id: sourceID), latest.revision == source.revision, latest.enabled, !latest.removed else { throw CancellationError() }
        latest.capabilities = capabilities; try await store.save(source: latest)
        if !works.isEmpty { try await store.saveRecord(kind: "catalog-cache", key: sourceID.key, value: works) }
        return CatalogInspection(sourceID: sourceID, works: works, errors: errors)
    }
    public func recommendations(sourceID: SourceID) async throws -> SourceRecommendations {
        let source = try await activeSource(sourceID)
        let adapter = try await adapter(for: sourceID)
        let context = ParserContext(source: source, client: DocumentSessionClient(client), renderer: renderer)
        let result: SourceRecommendations
        do { result = try await adapter.recommendations(context: context) }
        catch MangaError.unsupported(let feature) where feature == "浏览" {
            let works = try await store.allSourceWorks().filter { $0.id.sourceID == sourceID && SourceScope.contains($0.url, in: source.baseURL) }
            let channel = CatalogChannel(id: "saved-works", title: "已打开的作品", url: source.baseURL, kind: .browse)
            result = SourceRecommendations(source: source, channels: [channel], sections: [CatalogSection(channel: channel, works: works)], notices: ["此来源暂不提供分类或榜单，仍可打开已保存的作品。"])
        }
        try Task.checkCancellation()
        guard result.sourceID == sourceID, result.sourceRevision == source.revision,
              result.channels.allSatisfy({ SourceScope.contains($0.url, in: source.baseURL) }),
              result.sections.allSatisfy({ section in result.channels.contains(section.channel) && section.works.allSatisfy { $0.id.sourceID == sourceID && SourceScope.contains($0.url, in: source.baseURL) } }) else { throw MangaError.parseMismatch("推荐内容与来源不一致") }
        guard result.sections.contains(where: { !$0.works.isEmpty }) else { throw MangaError.parseMismatch("此来源暂未提供可浏览作品") }
        try await store.saveRecommendations(result)
        return result
    }
    public func cachedRecommendations(sourceID: SourceID) async throws -> SourceRecommendations? {
        let source = try await activeSource(sourceID)
        guard let result = try await store.record(kind: "recommendation-cache", key: sourceID.key, as: SourceRecommendations.self), result.sourceID == sourceID, result.sourceRevision == source.revision,
              result.fetchedAt <= Date().addingTimeInterval(300), result.fetchedAt > Date().addingTimeInterval(-7 * 86_400) else { return nil }
        return result
    }
    public func catalogPage(sourceID: SourceID, channelID: String, sort: CatalogSort = .sourceDefault, pageURL: URL? = nil) async throws -> CatalogPage {
        let source = try await activeSource(sourceID)
        guard let snapshot = try await cachedRecommendations(sourceID: sourceID), let channel = snapshot.channels.first(where: { $0.id == channelID }), channel.sorts.contains(sort) else { throw MangaError.unsupported("分类已失效，请刷新推荐") }
        let key = sourceID.key + ":" + String(source.revision) + ":" + channelID + ":" + sort.rawValue
        if let pageURL { guard SourceScope.contains(pageURL, in: source.baseURL), allowedCatalogPages[key]?.contains(pageURL) == true else { throw MangaError.invalidURL } }
        let result: CatalogPage
        if pageURL == nil, sort == .sourceDefault, (channel.kind == .popular && channel.url == source.baseURL || channel.id == "saved-works"), let section = snapshot.sections.first(where: { $0.channel.id == channelID }) { result = CatalogPage(works: section.works) }
        else {
            let context = ParserContext(source: source, client: DocumentSessionClient(client), renderer: renderer)
            result = try await adapter(for: sourceID).catalogPage(channel: channel, sort: sort, pageURL: pageURL, context: context)
        }
        try Task.checkCancellation()
        guard let latest = try await store.source(id: sourceID), latest.enabled, !latest.removed, latest.revision == source.revision else { throw CancellationError() }
        guard result.works.allSatisfy({ $0.id.sourceID == sourceID && SourceScope.contains($0.url, in: source.baseURL) }), result.nextURL.map({ SourceScope.contains($0, in: source.baseURL) }) != false else { throw MangaError.parseMismatch("分类内容跳转到了其他来源") }
        if pageURL == nil { allowedCatalogPages[key] = [] }
        if let next = result.nextURL { allowedCatalogPages[key, default: []].insert(next) }
        return result
    }
    public func setEnabled(_ enabled: Bool, sourceID: SourceID) async throws {
        try await store.setSourceEnabled(enabled, id: sourceID)
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
    public func loadWork(url: URL, sourceID: SourceID) async throws -> DetectedWork {
        try await tracked(sourceID) { adapter, original in
            let context = ParserContext(source: original.source, client: DocumentSessionClient(original.client), renderer: original.renderer)
            var work = try await adapter.details(url: url, context: context)
            guard work.id.sourceID == sourceID, SourceScope.contains(work.url, in: original.source.baseURL) else { throw MangaError.parseMismatch("作品来源不一致") }
            let chapters = try await adapter.chapters(work: work, context: context)
            guard !chapters.isEmpty, chapters.allSatisfy({ $0.id.sourceWorkID == work.id && SourceScope.contains($0.url, in: original.source.baseURL) }) else { throw MangaError.parseMismatch("没有取得有效章节目录") }
            work.checkedAt = Date(); work.latestChapter = chapters.last?.title ?? ""
            return DetectedWork(work: work, chapters: chapters)
        }
    }
    public func details(url: URL, sourceID: SourceID) async throws -> SourceWork {
        try await tracked(sourceID) { adapter, context in try await adapter.details(url: url, context: context) }
    }
    public func chapters(work: SourceWork) async throws -> [Chapter] {
        try await tracked(work.id.sourceID) { adapter, context in try await adapter.chapters(work: work, context: context) }
    }
    public func pages(chapter: Chapter, priority: RequestPriority = .reading) async throws -> [PageResource] {
        try await tracked(chapter.id.sourceWorkID.sourceID) { adapter, original in
            let context = ParserContext(source: original.source, client: PrioritizedHTTPClient(client: original.client, priority: priority), renderer: original.renderer)
            return try await adapter.pages(chapter: chapter, context: context)
        }
    }
    private func tracked<T: Sendable>(_ sourceID: SourceID, operation: @Sendable (any SourceAdapter, ParserContext) async throws -> T) async throws -> T {
        do {
            let result = try await operation(adapter(for: sourceID), context(for: sourceID))
            try await recordResult(sourceID: sourceID, error: nil); return result
        } catch let error as MangaError { try await recordResult(sourceID: sourceID, error: error); throw error }
    }
}
