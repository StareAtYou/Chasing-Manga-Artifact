import Foundation
import Observation
import SwiftUI
import MangaCore
import MangaPlatform
public enum AppSection: String, CaseIterable, Identifiable { case library, discovery, updates, downloads; public var id: Self { self }; public var title: String { switch self { case .library: "书架"; case .discovery: "发现"; case .updates: "更新"; case .downloads: "下载" } }; public var icon: String { switch self { case .library: "books.vertical"; case .discovery: "magnifyingglass"; case .updates: "sparkles"; case .downloads: "arrow.down.circle" } } }
@MainActor @Observable public final class AppContainer {
    public let store: LibraryStore
    public let sources: SourceService
    public let search: SearchService
    public let associations: AssociationService
    public let images: ImagePipeline
    public let downloads: DownloadManager
    public let updates: UpdateService
    public let navigation: NavigationState
    public let web: WebKitRenderer
    public let notificationService: NotificationService
    public let updateScheduler: UpdateScheduler
    public var library: [Work] = []
    public var catalog: [SourceWork] = []
    public var sourceList: [Source] = []
    public var downloadList: [DownloadTask] = []
    public var updateList: [UpdateObservation] = []
    public var history: [ReadingProgress] = []
    public var settings = UserSettings()
    public var path: [Route] = []
    public var section: AppSection = .library
    public var message: String?
    public var started = false
    public var searchResults: [SourceWork] = []
    public var searchErrors: [SourceID: String] = [:]
    public var searching = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var queryID = UUID()
    public static func defaultRoot() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = base.appendingPathComponent("ChasingManga", isDirectory: true); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    public init(root: URL? = nil, client injectedClient: (any HTTPClient)? = nil, registry: ParserRegistry? = nil, transfer injectedTransfer: (any PageTransferring)? = nil, notifications injectedNotifications: (any NotificationDelivering)? = nil, finishBackgroundEvents: @escaping @Sendable () -> Void = {}) throws {
        let root = try root ?? Self.defaultRoot(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("library.sqlite")); self.store = store
        let contexts = AccessContextStore(); let scheduler = RequestScheduler(); let client = injectedClient ?? URLSessionHTTPClient(scheduler: scheduler, contexts: contexts)
        web = WebKitRenderer(contexts: contexts)
        sources = SourceService(store: store, registry: registry ?? ParserRegistry(adapters: BuiltinSources.adapters()), client: client, verifier: ImageVerifier(), renderer: web)
        search = SearchService(store: store, sources: sources); associations = AssociationService(store: store)
        let files = try PageFileStore(root: root)
        let sources = self.sources
        images = ImagePipeline(client: client, files: files, refresh: { page, _ in
            guard let chapter = try await store.chapter(id: page.id.chapterID), let resource = try await sources.pages(chapter: chapter).first(where: { $0.id == page.id }) else { throw MangaError.expiredResource }; return resource
        })
        let transfer = try injectedTransfer ?? BackgroundTransfer(root: root, contexts: contexts, scheduler: scheduler, finishEvents: finishBackgroundEvents)
        downloads = try DownloadManager(store: store, transfer: transfer, verifier: ImageVerifier(), root: root, refresh: { try await sources.pages(chapter: $0) })
        notificationService = NotificationService(); updates = UpdateService(store: store, sources: sources, notifications: injectedNotifications ?? notificationService)
        updateScheduler = UpdateScheduler(updates: updates); navigation = NavigationState(store: store, downloads: downloads)
    }
    public func start(registerBuiltins: Bool = true) async {
        guard !started else { return }; started = true
        await perform {
            if registerBuiltins { for source in BuiltinSources.candidates() where try await store.source(id: source.id) == nil { try await store.save(source: source) } }
            try await downloads.restore(); try await refresh()
        }
        updateScheduler.onAppActive()
    }
    public func refresh() async throws {
        library = try await store.library(); catalog = try await store.allSourceWorks(); sourceList = try await store.sources()
        downloadList = try await downloads.tasks(); updateList = try await updates.observations(); history = try await store.history(); settings = try await store.settings()
    }
    public func perform(_ action: () async throws -> Void) async { do { try await action() } catch is CancellationError { } catch { message = error.localizedDescription } }
    public func open(_ work: Work) async { await perform { path.append(try await navigation.open(workID: work.id)) } }
    public var validatedWorks: [SourceWork] {
        catalog.filter { work in sourceList.contains { $0.id == work.id.sourceID && $0.enabled && $0.capabilities.contains(.readable) } }
    }
    public func openWorkURL(_ url: URL, sourceID: SourceID) async {
        await perform {
            guard let source = try await store.source(id: sourceID), SourceScope.contains(url, in: source.baseURL) else { throw MangaError.invalidURL }
            let work = try await sources.details(url: url, sourceID: sourceID)
            await select(work)
        }
    }
    public func previewFile(report: DetectionReport, candidate: DetectionCandidate, page: PageResource) async throws -> URL {
        let id = PageID(chapterID: page.id.chapterID, externalID: "preview:" + report.detectionID.uuidString + ":" + candidate.id + ":" + page.id.externalID)
        let preview = PageResource(id: id, ordinal: page.ordinal, request: page.request, expiresAt: page.expiresAt)
        return try await images.file(for: preview, sourceID: report.sourceID)
    }
    public func select(_ result: SourceWork) async { await perform {
        let work = try await sources.details(url: result.url, sourceID: result.id.sourceID); let chapters = try await sources.chapters(work: work)
        try await store.save(sourceWork: work, chapters: chapters); let grouped = try await store.createWork(from: work.id, onShelf: false)
        path.append(.work(grouped.id)); try await refresh()
    } }
    public func addToShelf(_ workID: WorkID, sourceWorkID: SourceWorkID) async { await perform { try await store.setOnShelf(true, workID: workID); try await updates.setFollowed(true, sourceWorkID: sourceWorkID); _ = await updates.check(sourceWorkIDs: [sourceWorkID]); try await refresh() } }
    public func sourceName(_ id: SourceID) -> String { sourceList.first { $0.id == id }?.name ?? "已删除的来源" }
    public func searchFor(_ query: String, sourceIDs: [SourceID]) {
        searchTask?.cancel(); queryID = UUID(); let id = queryID; searchResults = []; searchErrors = [:]
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { searching = false; Task { await search.cancel() }; return }
        searching = true
        searchTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            for await event in await search.search(query: query, sourceIDs: sourceIDs, queryID: id) {
                guard !Task.isCancelled, queryID == event.queryID else { continue }
                switch event { case .results(_, _, let works): searchResults += works; case .failure(_, let source, let error): searchErrors[source] = error.localizedDescription; case .finished: searching = false }
            }
            if queryID == id { searching = false }
        }
    }
    public func cancelSearch() { searchTask?.cancel(); searching = false; Task { await search.cancel() } }
    public func setEnabled(_ enabled: Bool, sourceID: SourceID) async { await perform { try await sources.setEnabled(enabled, sourceID: sourceID); if !enabled { try await downloads.pause(sourceID: sourceID) }; try await refresh() } }
    public func removeSource(_ id: SourceID) async { await perform { try await downloads.pause(sourceID: id); try await sources.remove(sourceID: id); await web.remove(sourceID: id); try await refresh() } }
    public func saveSettings() async { await perform { try await store.save(settings: settings) } }
}
