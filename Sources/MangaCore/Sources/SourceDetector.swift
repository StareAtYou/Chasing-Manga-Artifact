import Foundation
private actor DetectionHTTPClient: HTTPClient {
    let client: any HTTPClient
    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    var cached: [ResourceRequest: ResourceResponse] = [:]
    var count = 0
    init(_ client: any HTTPClient) { self.client = client }
    func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw MangaError.timedOut }
        if let response = cached[request] { return response }
        guard count < 30 else { throw MangaError.unsupported("检测达到 30 次请求上限，请补充更精确的样本") }
        count += 1
        let response = try await client.send(request, sourceID: sourceID, priority: .probe)
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw MangaError.timedOut }
        cached[request] = response
        return response
    }
}
public struct SourceDetector: Sendable {
    private let registry: ParserRegistry
    private let client: any HTTPClient
    private let verifier: any ImageVerifying
    private let renderer: (any PageRenderer)?
    public init(registry: ParserRegistry, client: any HTTPClient, verifier: any ImageVerifying, renderer: (any PageRenderer)? = nil) {
        self.registry = registry; self.client = client; self.verifier = verifier; self.renderer = renderer
    }
    public func detect(source: Source, samples: [URL]) async -> DetectionReport {
        await withTaskGroup(of: DetectionReport.self) { group in
            group.addTask { await detectWithinBudget(source: source, samples: samples) }
            group.addTask {
                do { try await Task.sleep(for: .seconds(60)) } catch { return DetectionReport(source: source, status: .cancelled) }
                return DetectionReport(source: source, status: .accessFailure, error: .timedOut)
            }
            let result = await group.next() ?? DetectionReport(source: source, status: .cancelled)
            group.cancelAll(); return result
        }
    }
    private func detectWithinBudget(source: Source, samples: [URL]) async -> DetectionReport {
        guard samples.allSatisfy({ SourceScope.contains($0, in: source.baseURL) }) else { return DetectionReport(source: source, status: .needsSamples, error: .unsupported("样本必须属于当前来源的域名和目录，请确认来源地址")) }
        let limitedClient = DetectionHTTPClient(client)
        let context = ParserContext(source: source, client: limitedClient, renderer: renderer)
        var candidates: [DetectionCandidate] = []; var accessError: MangaError?
        var hadSamples = !samples.isEmpty
        for adapter in registry.adapters {
            if Task.isCancelled { return DetectionReport(source: source, status: .cancelled) }
            var urls = Array(Set(samples)).sorted { $0.absoluteString < $1.absoluteString }
            if urls.isEmpty {
                do {
                    urls = try await adapter.browse(context: context).map(\.url).filter { SourceScope.contains($0, in: source.baseURL) }
                    hadSamples = hadSamples || !urls.isEmpty
                } catch let error as MangaError { if Self.isAccessFailure(error) { accessError = error } } catch { }
            }
            var detected: [DetectedWork] = []; var chapterCount = 0; var fingerprints: [String] = []; var previews: [PageResource] = []
            var twoChaptersPerWork = true
            for url in urls.prefix(4) {
                do {
                    let work = try await adapter.details(url: url, context: context)
                    guard work.id.sourceID == source.id, SourceScope.contains(work.url, in: source.baseURL) else { throw MangaError.parseMismatch("作品超出来源范围") }
                    let chapters = try await adapter.chapters(work: work, context: context)
                    guard chapters.allSatisfy({ $0.id.sourceWorkID == work.id && SourceScope.contains($0.url, in: source.baseURL) }) else { throw MangaError.parseMismatch("章节超出来源范围") }
                    let available = chapters.filter { $0.access == .available }
                    guard let first = available.first else { throw MangaError.parseMismatch("没有公开可读章节") }
                    let chosen = available.count > 1 ? [first, available.last!] : [first]
                    var workFingerprints: [String] = []; var workPreviews: [PageResource] = []
                    for chapter in chosen {
                        let sample = try await adapter.validationPages(chapter: chapter, context: context)
                        let pages = sample.pages
                        guard !pages.isEmpty, sample.totalCount >= pages.count,
                              pages.first?.ordinal == 0, pages.last?.ordinal == sample.totalCount - 1,
                              pages.allSatisfy({ $0.id.chapterID == chapter.id }), Set(pages.map(\.id)).count == pages.count,
                              pages.map(\.ordinal) == pages.map(\.ordinal).sorted(),
                              Set(pages.map(\.ordinal)).count == pages.count else { throw MangaError.parseMismatch("页序不完整") }
                        let representatives = pages.count > 1 ? [pages.first!, pages.last!] : [pages[0]]
                        for page in representatives {
                            let response = try await limitedClient.send(page.request, sourceID: source.id, priority: .probe)
                            _ = try verifier.verify(ImageResourceDecoder.decode(response.data, request: page.request))
                            workPreviews.append(page)
                        }
                        workFingerprints.append(semanticID(url) + "|" + semanticID(chapter.url) + "|count:\(sample.totalCount)|" + pages.map { page in
                            // Only the documented authentication parameters are ephemeral.
                            var value = URLComponents(url: page.request.url, resolvingAgainstBaseURL: false)!
                            value.queryItems = value.queryItems?.filter { !["sign", "signature", "token", "expires", "expiry", "key"].contains($0.name.lowercased()) }
                            value.fragment = nil
                            return "\(page.ordinal):\(value.string ?? page.request.url.path)"
                        }.joined(separator: ","))
                    }
                    detected.append(DetectedWork(work: work, chapters: chapters)); chapterCount += chosen.count
                    twoChaptersPerWork = twoChaptersPerWork && chosen.count == 2
                    fingerprints += workFingerprints; previews += workPreviews
                    if detected.count == 2 { break }
                } catch is CancellationError { return DetectionReport(source: source, status: .cancelled) }
                catch let error as MangaError { if Self.isAccessFailure(error) { accessError = error } }
                catch { accessError = .networkUnavailable }
            }
            if !detected.isEmpty {
                let level: ValidationLevel = detected.count >= 2 && twoChaptersPerWork ? .verified : .limited
                let binding = ParserBinding(parserID: adapter.id, version: adapter.version, level: level, sampledWorks: detected.count, sampledChapters: chapterCount)
                candidates.append(DetectionCandidate(binding: binding, works: detected, previewResources: previews, fingerprint: fingerprints.sorted()))
            }
        }
        if Task.isCancelled { return DetectionReport(source: source, status: .cancelled) }
        guard let best = candidates.first else {
            if let accessError { return DetectionReport(source: source, status: .accessFailure, error: accessError) }
            return DetectionReport(source: source, status: hadSamples ? .unsupported : .needsSamples)
        }
        if candidates.contains(where: { $0.fingerprint != best.fingerprint }) { return DetectionReport(source: source, status: .ambiguous, candidates: candidates) }
        return DetectionReport(source: source, status: best.binding.level == .verified ? .verified : .limited, candidates: [best])
    }
    private static func isAccessFailure(_ error: MangaError) -> Bool {
        switch error { case .parseMismatch, .unsupported: false; default: true }
    }
}
