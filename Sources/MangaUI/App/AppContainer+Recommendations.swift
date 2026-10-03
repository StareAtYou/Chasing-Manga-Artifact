import Foundation
import MangaCore
extension AppContainer {
    private var validRecommendationSnapshots: [SourceRecommendations] {
        sourceList.compactMap { source in
            guard source.enabled, !source.removed, let snapshot = recommendationSnapshots[source.id], snapshot.sourceRevision == source.revision else { return nil }
            return snapshot
        }
    }
    public var currentRecommendations: [SourceRecommendations] { validRecommendationSnapshots.filter { recommendationErrors[$0.sourceID] == nil && (!recommendationCachedSourceIDs.contains($0.sourceID) || $0.fetchedAt > Date().addingTimeInterval(-900)) } }
    public var cachedRecommendations: [SourceRecommendations] { validRecommendationSnapshots.filter { recommendationErrors[$0.sourceID] != nil || (recommendationCachedSourceIDs.contains($0.sourceID) && $0.fetchedAt <= Date().addingTimeInterval(-900)) } }
    public func isRecommendationCached(_ id: SourceID) -> Bool { recommendationCachedSourceIDs.contains(id) || recommendationErrors[id] != nil }
    public var recommendationGenres: [String] {
        Array(Set(currentRecommendations.flatMap { $0.channels.compactMap(\.genre) })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    public func recommendationSnapshot(for id: SourceID) -> SourceRecommendations? { validRecommendationSnapshots.first { $0.sourceID == id } }
    public func prepareRecommendations(force: Bool = false) async {
        let available = sourceList.filter { $0.enabled && !$0.removed && ($0.binding != nil || BuiltinSources.candidateAdapter(for: $0) != nil) }
        // Three sources at a time; each failure preserves other sources' results.
        for start in stride(from: 0, to: available.count, by: 3) {
            await withTaskGroup(of: Void.self) { group in
                for source in available[start..<min(start + 3, available.count)] {
                    group.addTask { await self.refreshRecommendations(sourceID: source.id, force: force) }
                }
            }
        }
    }
    public func refreshRecommendations(sourceID: SourceID, force: Bool = true) async {
        guard !recommendationLoading.contains(sourceID) else { return }
        recommendationLoading.insert(sourceID); defer { recommendationLoading.remove(sourceID) }
        if recommendationSnapshot(for: sourceID) == nil, let cache = try? await sources.cachedRecommendations(sourceID: sourceID) { recommendationSnapshots[sourceID] = cache; recommendationCachedSourceIDs.insert(sourceID) }
        if !force, let cache = recommendationSnapshot(for: sourceID), cache.fetchedAt > Date().addingTimeInterval(-900) { return }
        do {
            let result = try await sources.recommendations(sourceID: sourceID)
            guard sourceList.contains(where: { $0.id == sourceID && $0.enabled && !$0.removed && $0.revision == result.sourceRevision }) else { return }
            recommendationSnapshots[sourceID] = result; recommendationCachedSourceIDs.remove(sourceID); recommendationErrors[sourceID] = nil; genrePreviews[sourceID] = []
            // Real category pages provide previews; title/order is labelled by source.
            let priority = ["热血", "恋爱", "冒险", "奇幻", "科幻", "悬疑"]
            let genres = result.channels.filter { $0.kind == .genre }.sorted { (priority.firstIndex(of: $0.genre ?? "") ?? 100) < (priority.firstIndex(of: $1.genre ?? "") ?? 100) }
            for channel in genres.prefix(2) {
                do {
                    let sort: CatalogSort = channel.sorts.contains(.popularity) ? .popularity : .sourceDefault
                    let page = try await sources.catalogPage(sourceID: sourceID, channelID: channel.id, sort: sort)
                    guard recommendationSnapshot(for: sourceID)?.sourceRevision == result.sourceRevision else { return }
                    if !page.works.isEmpty { genrePreviews[sourceID, default: []].append(CatalogSection(channel: channel, works: Array(page.works.prefix(12)))) }
                } catch is CancellationError { return } catch { /* A preview failure leaves the source and its full categories available. */ }
            }
        } catch is CancellationError { } catch { recommendationErrors[sourceID] = error.localizedDescription }
    }
}
