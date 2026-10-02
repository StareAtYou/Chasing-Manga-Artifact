import Foundation
public actor DownloadManager {
    public typealias Refresh = @Sendable (Chapter) async throws -> [PageResource]
    private let store: LibraryStore
    private let transfer: any PageTransferring
    private let verifier: any ImageVerifying
    public let offlineDirectory: URL
    private let refresh: Refresh?
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var tokens: [UUID: UUID] = [:]
    public init(store: LibraryStore, transfer: any PageTransferring, verifier: any ImageVerifying, root: URL, refresh: Refresh? = nil) throws {
        self.store = store; self.transfer = transfer; self.verifier = verifier; self.refresh = refresh
        offlineDirectory = root.appendingPathComponent("offline", isDirectory: true)
        try FileManager.default.createDirectory(at: offlineDirectory, withIntermediateDirectories: true)
    }
    public func task(id: UUID) async throws -> DownloadTask? { try await store.downloadTask(id: id) }
    public func tasks() async throws -> [DownloadTask] { try await store.downloadTasks() }
    private func validatePages(_ pages: [PageResource], chapter: Chapter) throws {
        guard !pages.isEmpty, pages.allSatisfy({ $0.id.chapterID == chapter.id }), Set(pages.map(\.id)).count == pages.count, Set(pages.map(\.ordinal)).count == pages.count else { throw MangaError.parseMismatch("下载页面列表无效") }
    }
    public func enqueue(chapter: Chapter, pages: [PageResource]) async throws -> UUID {
        try validatePages(pages, chapter: chapter)
        if let existing = try await tasks().first(where: { $0.chapter.id == chapter.id && $0.state != .cancelled }) { return existing.id }
        let source = try await store.source(id: chapter.id.sourceWorkID.sourceID)
        let task = DownloadTask(chapter: chapter, pages: pages.sorted { $0.ordinal < $1.ordinal }, sourceSnapshot: source)
        _ = try await store.saveDownload(task: task, manifest: OfflineManifest(taskID: task.id, chapterID: chapter.id))
        await schedule(); return task.id
    }
    private func folder(_ id: UUID) -> URL { offlineDirectory.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func schedule() async {
        guard let tasks = try? await tasks() else { return }
        for task in tasks where jobs.count < 2 && task.state == .queued && jobs[task.id] == nil {
            tokens[task.id] = task.generation
            jobs[task.id] = Task { await self.run(id: task.id, generation: task.generation) }
        }
    }
    private func stillCurrent(_ id: UUID, _ generation: UUID) throws { try Task.checkCancellation(); guard tokens[id] == generation else { throw CancellationError() } }
    private func valid(_ entry: OfflineEntry, taskID: UUID) -> Bool {
        guard entry.filename == ContentDigest.filename(entry.pageID), let data = try? Data(contentsOf: folder(taskID).appendingPathComponent(entry.filename)), data.count == entry.bytes, ContentDigest.hex(data) == entry.digest, (try? verifier.verify(data)) != nil else { return false }
        return true
    }
    private func save(_ task: DownloadTask, _ manifest: OfflineManifest) async throws {
        try stillCurrent(task.id, task.generation)
        guard try await store.saveDownload(task: task, manifest: manifest, expectedGeneration: task.generation) else { throw CancellationError() }
    }
    private func run(id: UUID, generation: UUID) async {
        do {
            guard var task = try await task(id: id), task.generation == generation else { throw CancellationError() }
            var manifest = try await store.offlineManifest(taskID: id) ?? OfflineManifest(taskID: id, chapterID: task.chapter.id)
            task.state = .running; task.error = nil; try await save(task, manifest)
            try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
            if let refresh, task.needsRefresh != false || task.pages.contains(where: { ($0.expiresAt ?? .distantFuture) <= Date() }) {
                task.pages = try await refresh(task.chapter); try validatePages(task.pages, chapter: task.chapter)
            }
            task.needsRefresh = false
            let identities = Set(task.pages.map(\.id)); manifest.entries = manifest.entries.filter { identities.contains($0.pageID) && valid($0, taskID: id) }.map { entry in
                let ordinal = task.pages.first { $0.id == entry.pageID }!.ordinal
                return OfflineEntry(pageID: entry.pageID, ordinal: ordinal, filename: entry.filename, digest: entry.digest, bytes: entry.bytes)
            }
            for page in task.pages.sorted(by: { $0.ordinal < $1.ordinal }) {
                try stillCurrent(id, generation)
                if let source = try await store.source(id: task.chapter.id.sourceWorkID.sourceID), !source.enabled || source.removed { throw MangaError.unsupported("来源已停用或删除") }
                if manifest.entries.contains(where: { $0.pageID == page.id }) { continue }
                let destination = folder(id).appendingPathComponent(ContentDigest.filename(page.id) + ".partial." + generation.uuidString)
                defer { try? FileManager.default.removeItem(at: destination) }
                let result = try await transfer.download(page.request, sourceID: page.id.chapterID.sourceWorkID.sourceID, taskID: id, to: destination)
                guard (200..<300).contains(result.statusCode) else { throw MangaError.accessRestricted(result.statusCode) }
                let data = try Data(contentsOf: result.file); _ = try verifier.verify(data); try stillCurrent(id, generation)
                let filename = ContentDigest.filename(page.id); let permanent = folder(id).appendingPathComponent(filename)
                try data.write(to: permanent, options: .atomic)
                manifest.entries.removeAll { $0.pageID == page.id }
                manifest.entries.append(OfflineEntry(pageID: page.id, ordinal: page.ordinal, filename: filename, digest: ContentDigest.hex(data), bytes: data.count))
                task.completedPages = manifest.entries.count; task.bytes = manifest.entries.reduce(0) { $0 + $1.bytes }; task.updatedAt = Date()
                try await save(task, manifest)
            }
            guard manifest.entries.count == task.pages.count, manifest.entries.allSatisfy({ valid($0, taskID: id) }) else { throw MangaError.invalidImage }
            task.state = .completed; task.completedPages = manifest.entries.count; try await save(task, manifest)
        } catch is CancellationError { }
        catch {
            if tokens[id] == generation, var task = try? await task(id: id), task.generation == generation {
                let mapped = (error as? MangaError) ?? ((error as? CocoaError)?.code == .fileWriteOutOfSpace ? .diskFull : .storage(error.localizedDescription))
                task.error = mapped; task.state = mapped == .diskFull ? .paused : .failed
                if case .unsupported = mapped { task.state = .paused }
                _ = try? await store.saveDownload(task: task, manifest: nil, expectedGeneration: generation)
            }
        }
        if tokens[id] == generation { jobs.removeValue(forKey: id); tokens.removeValue(forKey: id) }
        await schedule()
    }
    private func transition(_ id: UUID, to state: DownloadState) async throws {
        guard var task = try await task(id: id) else { return }
        let old = task.generation; task.generation = UUID(); task.state = state; if state == .queued { task.needsRefresh = true }; task.error = nil; task.updatedAt = Date()
        guard try await store.saveDownload(task: task, manifest: nil, expectedGeneration: old) else { return }
        jobs.removeValue(forKey: id)?.cancel(); tokens.removeValue(forKey: id)
        await schedule()
    }
    public func pause(taskID: UUID) async throws { if try await task(id: taskID)?.state != .completed { try await transition(taskID, to: .paused) } }
    public func resume(taskID: UUID) async throws { if try await task(id: taskID)?.state != .completed { try await transition(taskID, to: .queued) } }
    public func retry(taskID: UUID) async throws { try await resume(taskID: taskID) }
    public func cancel(taskID: UUID) async throws { try await transition(taskID, to: .cancelled) }
    public func pause(sourceID: SourceID) async throws { for task in try await tasks() where task.chapter.id.sourceWorkID.sourceID == sourceID && [.running, .queued].contains(task.state) { try await pause(taskID: task.id) } }
    public func deleteDownloaded(chapterID: ChapterID) async throws {
        for task in try await tasks() where task.chapter.id == chapterID {
            try await cancel(taskID: task.id)
            if FileManager.default.fileExists(atPath: folder(task.id).path) { try FileManager.default.removeItem(at: folder(task.id)) }
            try await store.deleteDownload(taskID: task.id)
        }
    }
    public func restore() async throws {
        _ = try await transfer.recoverTransfers()
        for var task in try await tasks() where task.state != .cancelled {
            var manifest = try await store.offlineManifest(taskID: task.id) ?? OfflineManifest(taskID: task.id, chapterID: task.chapter.id)
            let before = manifest.entries.count; manifest.entries = manifest.entries.filter { valid($0, taskID: task.id) }
            task.completedPages = manifest.entries.count; task.bytes = manifest.entries.reduce(0) { $0 + $1.bytes }
            if task.state == .completed && (before != manifest.entries.count || manifest.entries.count != task.pages.count) { task.state = .failed; task.error = .invalidImage }
            if task.state == .running { task.state = .queued }; if task.state == .queued { task.needsRefresh = true }
            _ = try await store.saveDownload(task: task, manifest: manifest, expectedGeneration: task.generation)
        }
        await schedule()
    }
    public func offlineManifest(chapterID: ChapterID) async throws -> (DownloadTask, OfflineManifest)? {
        guard let task = try await tasks().first(where: { $0.chapter.id == chapterID && $0.state != .cancelled }), let manifest = try await store.offlineManifest(taskID: task.id) else { return nil }
        return (task, manifest)
    }
    public func offlineFiles(chapterID: ChapterID) async throws -> [PageID: URL] {
        guard let (task, manifest) = try await offlineManifest(chapterID: chapterID), task.state == .completed, manifest.entries.count == task.pages.count, Set(manifest.entries.map(\.pageID)) == Set(task.pages.map(\.id)), manifest.entries.allSatisfy({ valid($0, taskID: task.id) }) else { throw MangaError.invalidImage }
        return Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.pageID, folder(task.id).appendingPathComponent($0.filename)) })
    }
    public func offlinePages(chapterID: ChapterID) async throws -> [URL] {
        let files = try await offlineFiles(chapterID: chapterID)
        guard let (task, _) = try await offlineManifest(chapterID: chapterID) else { throw MangaError.invalidImage }
        return try task.pages.sorted { $0.ordinal < $1.ordinal }.map { guard let file = files[$0.id] else { throw MangaError.invalidImage }; return file }
    }
}
