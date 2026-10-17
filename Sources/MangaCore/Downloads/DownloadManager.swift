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
    private struct Queued: Sendable { let id: UUID; let generation: UUID; let work: SourceWorkID; let date: Date }
    private struct Prepared: Sendable { let file: URL; let entry: OfflineEntry }
    private var queued: [UUID: Queued] = [:]
    private var jobWorks: [UUID: SourceWorkID] = [:]
    // This local admission budget is shared by all chapters/works; the transport
    // separately applies download priority against visible reading requests.
    private let pageSlots = RequestScheduler(globalLimit: 8, sourceLimit: 6)
    private let startupRecovery: Task<Void, Never>
    private var cleanup: Task<Void, Never>?
    private var removingWorks = Set<SourceWorkID>()
    public init(store: LibraryStore, transfer: any PageTransferring, verifier: any ImageVerifying, root: URL, refresh: Refresh? = nil) throws {
        self.store = store; self.transfer = transfer; self.verifier = verifier; self.refresh = refresh
        offlineDirectory = root.appendingPathComponent("offline", isDirectory: true)
        try FileManager.default.createDirectory(at: offlineDirectory, withIntermediateDirectories: true)
        let trash = offlineDirectory.appendingPathComponent(".removing", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? []
        let directory = offlineDirectory
        startupRecovery = Task.detached(priority: .utility) {
            for operation in leftovers {
                var unresolved = false
                for detached in (try? FileManager.default.contentsOfDirectory(at: operation, includingPropertiesForKeys: nil)) ?? [] {
                    guard let id = UUID(uuidString: detached.lastPathComponent) else { unresolved = true; continue }
                    do {
                        if try await store.downloadTask(id: id) != nil {
                            let original = directory.appendingPathComponent(id.uuidString, isDirectory: true)
                            if !FileManager.default.fileExists(atPath: original.path) { try FileManager.default.moveItem(at: detached, to: original) }
                            else { unresolved = true }
                        } else { try FileManager.default.removeItem(at: detached) }
                    } catch { unresolved = true }
                }
                if !unresolved { try? FileManager.default.removeItem(at: operation) }
            }
        }
        cleanup = startupRecovery
    }
    public func task(chapterID: ChapterID) async throws -> DownloadTask? { try await store.downloadTask(chapterID: chapterID) }
    public func task(id: UUID) async throws -> DownloadTask? { try await store.downloadTask(id: id) }
    public func tasks() async throws -> [DownloadTask] { try await store.downloadTasks() }
    private func validatePages(_ pages: [PageResource], chapter: Chapter) throws {
        guard !pages.isEmpty, pages.allSatisfy({ $0.id.chapterID == chapter.id }), Set(pages.map(\.id)).count == pages.count, Set(pages.map(\.ordinal)).count == pages.count else { throw MangaError.parseMismatch("下载页面列表无效") }
    }
    public func preparationEpoch(for id: SourceWorkID) async throws -> UUID {
        guard !removingWorks.contains(id) else { throw CancellationError() }
        return try await store.downloadPreparationEpoch(for: id)
    }
    public func enqueue(chapter: Chapter, pages: [PageResource], preparationEpoch: UUID? = nil) async throws -> UUID {
        try Task.checkCancellation(); try validatePages(pages, chapter: chapter)
        let epoch: UUID
        if let preparationEpoch { epoch = preparationEpoch } else { epoch = try await self.preparationEpoch(for: chapter.id.sourceWorkID) }
        guard !removingWorks.contains(chapter.id.sourceWorkID) else { throw CancellationError() }
        if let existing = try await task(chapterID: chapter.id) {
            if [.failed, .paused].contains(existing.state) { try await resume(taskID: existing.id, preparationEpoch: epoch) }
            try await store.ensureDownloadShelfOwner(for: chapter.id.sourceWorkID, expectedEpoch: epoch)
            return existing.id
        }
        let source = try await store.source(id: chapter.id.sourceWorkID.sourceID)
        let task = DownloadTask(chapter: chapter, pages: pages.sorted { $0.ordinal < $1.ordinal }, sourceSnapshot: source)
        try Task.checkCancellation()
        guard !removingWorks.contains(chapter.id.sourceWorkID) else { throw CancellationError() }
        _ = try await store.saveDownload(task: task, manifest: OfflineManifest(taskID: task.id, chapterID: chapter.id), expectedWorkEpoch: epoch, bringToShelf: true)
        remember(task); schedule(); return task.id
    }
    private func folder(_ id: UUID) -> URL { offlineDirectory.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func remember(_ task: DownloadTask) {
        if task.state == .queued { queued[task.id] = Queued(id: task.id, generation: task.generation, work: task.chapter.id.sourceWorkID, date: task.updatedAt) }
        else { queued.removeValue(forKey: task.id) }
    }
    private func schedule() {
        while jobs.count < 4 {
            let counts = Dictionary(grouping: jobWorks.values, by: { $0 }).mapValues(\.count)
            let eligible = queued.values.filter { jobs[$0.id] == nil && !removingWorks.contains($0.work) && counts[$0.work, default: 0] < 2 }
            guard let next = eligible.min(by: { a, b in
                let ca = counts[a.work, default: 0], cb = counts[b.work, default: 0]
                return ca == cb ? a.date < b.date : ca < cb
            }) else { return }
            queued.removeValue(forKey: next.id); tokens[next.id] = next.generation; jobWorks[next.id] = next.work
            jobs[next.id] = Task { await self.run(id: next.id, generation: next.generation) }
        }
    }
    private func stillCurrent(_ id: UUID, _ generation: UUID) throws { try Task.checkCancellation(); guard tokens[id] == generation else { throw CancellationError() } }
    private func valid(_ entry: OfflineEntry, taskID: UUID) -> Bool {
        guard entry.filename == ContentDigest.filename(entry.pageID), let data = try? Data(contentsOf: folder(taskID).appendingPathComponent(entry.filename)), data.count == entry.bytes, ContentDigest.hex(data) == entry.digest, (try? verifier.verify(data)) != nil else { return false }
        return true
    }
    private func requiresFreshPages(_ task: DownloadTask) -> Bool {
        task.pages.isEmpty || task.pages.contains { $0.request.accessContextID != nil || ($0.expiresAt ?? .distantFuture) <= Date() }
    }
    private func save(_ task: DownloadTask, _ manifest: OfflineManifest) async throws {
        try stillCurrent(task.id, task.generation)
        guard try await store.saveDownload(task: task, manifest: manifest, expectedGeneration: task.generation) else { throw CancellationError() }
    }
    private func run(id: UUID, generation: UUID) async {
        await startupRecovery.value
        let directory = folder(id)
        defer {
            Task.detached(priority: .utility) {
                for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent.hasSuffix(".partial." + generation.uuidString) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        do {
            guard var task = try await task(id: id), task.generation == generation else { throw CancellationError() }
            var manifest = try await store.offlineManifest(taskID: id) ?? OfflineManifest(taskID: id, chapterID: task.chapter.id)
            task.state = .running; task.error = nil; try await save(task, manifest)
            try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
            if let refresh, task.needsRefresh != false || task.pages.contains(where: { ($0.expiresAt ?? .distantFuture) <= Date() }) {
                task.pages = try await refresh(task.chapter); try validatePages(task.pages, chapter: task.chapter)
            }
            task.needsRefresh = false
            task.refreshRequested = false
            let identities = Set(task.pages.map(\.id)); manifest.entries = manifest.entries.filter { identities.contains($0.pageID) && valid($0, taskID: id) }.map { entry in
                let ordinal = task.pages.first { $0.id == entry.pageID }!.ordinal
                return OfflineEntry(pageID: entry.pageID, ordinal: ordinal, filename: entry.filename, digest: entry.digest, bytes: entry.bytes)
            }
            task.bytes = manifest.entries.reduce(0) { $0 + $1.bytes }
            // Persist the cleared refresh marker even if the very first image
            // fails, so legacy recovery cannot retry itself on every launch.
            try await save(task, manifest)
            let missing = task.pages.sorted { $0.ordinal < $1.ordinal }.filter { page in !manifest.entries.contains { $0.pageID == page.id } }
            let transfer = self.transfer, verifier = self.verifier, slots = self.pageSlots
            let directory = folder(id)
            try await withThrowingTaskGroup(of: Result<Prepared, Error>.self) { group in
                var index = 0
                func add(_ page: PageResource) {
                    group.addTask {
                        do { return .success(try await Self.fetch(page, id: id, generation: generation, directory: directory, transfer: transfer, verifier: verifier, slots: slots)) }
                        catch { return .failure(error) }
                    }
                }
                for _ in 0..<min(6, missing.count) { add(missing[index]); index += 1 }
                var failure: Error?
                while let result = try await group.next() {
                    try stillCurrent(id, generation)
                    switch result {
                    case .success(let prepared):
                        defer { try? FileManager.default.removeItem(at: prepared.file) }
                        if let source = try await store.source(id: task.chapter.id.sourceWorkID.sourceID), !source.enabled || source.removed { throw MangaError.unsupported("来源已停用或删除") }
                        try stillCurrent(id, generation)
                        let permanent = folder(id).appendingPathComponent(prepared.entry.filename)
                        if FileManager.default.fileExists(atPath: permanent.path) { try FileManager.default.removeItem(at: permanent) }
                        try FileManager.default.moveItem(at: prepared.file, to: permanent)
                        manifest.entries.append(prepared.entry)
                        task.completedPages = manifest.entries.count; task.bytes += prepared.entry.bytes; task.updatedAt = Date()
                        try await save(task, manifest)
                    case .failure(let error): if failure == nil { failure = error }
                    }
                    // Finish already received pages on failure, but do not launch more requests.
                    if failure == nil, index < missing.count { add(missing[index]); index += 1 }
                }
                if let failure { throw failure }
            }
            guard manifest.entries.count == task.pages.count, Set(manifest.entries.map(\.pageID)) == identities else { throw MangaError.invalidImage }
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
        if tokens[id] == generation { jobs.removeValue(forKey: id); tokens.removeValue(forKey: id); jobWorks.removeValue(forKey: id) }
        schedule()
    }
    private nonisolated static func fetch(_ page: PageResource, id: UUID, generation: UUID, directory: URL, transfer: any PageTransferring, verifier: any ImageVerifying, slots: RequestScheduler) async throws -> Prepared {
        let lease = try await slots.acquire(sourceID: page.id.chapterID.sourceWorkID.sourceID, priority: .reading)
        do {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(ContentDigest.filename(page.id) + ".partial." + generation.uuidString)
            do {
                let result = try await transfer.download(page.request, sourceID: page.id.chapterID.sourceWorkID.sourceID, taskID: id, to: destination)
                guard (200..<300).contains(result.statusCode) else { throw MangaError.accessRestricted(result.statusCode) }
                let data = try Data(contentsOf: result.file, options: .mappedIfSafe)
                _ = try verifier.verify(data); try Task.checkCancellation()
                let entry = OfflineEntry(pageID: page.id, ordinal: page.ordinal, filename: ContentDigest.filename(page.id), digest: ContentDigest.hex(data), bytes: data.count)
                await slots.release(lease)
                return Prepared(file: result.file, entry: entry)
            } catch { try? FileManager.default.removeItem(at: destination); throw error }
        } catch { await slots.release(lease); throw error }
    }
    private func transition(_ id: UUID, to state: DownloadState, preparationEpoch: UUID? = nil) async throws {
        guard var task = try await task(id: id) else { return }
        let old = task.generation; task.generation = UUID(); task.state = state
        if state == .queued { task.needsRefresh = true; task.refreshRequested = true }
        task.error = nil; task.updatedAt = Date()
        guard try await store.saveDownload(task: task, manifest: nil, expectedGeneration: old, expectedWorkEpoch: preparationEpoch, bringToShelf: state == .queued) else { return }
        jobs.removeValue(forKey: id)?.cancel(); tokens.removeValue(forKey: id); jobWorks.removeValue(forKey: id); remember(task)
        schedule()
    }
    public func pause(taskID: UUID) async throws { if try await task(id: taskID)?.state != .completed { try await transition(taskID, to: .paused) } }
    public func resume(taskID: UUID, preparationEpoch: UUID? = nil) async throws {
        try Task.checkCancellation()
        guard let task = try await task(id: taskID), !removingWorks.contains(task.chapter.id.sourceWorkID) else { return }
        let epoch: UUID
        if let preparationEpoch { epoch = preparationEpoch } else { epoch = try await self.preparationEpoch(for: task.chapter.id.sourceWorkID) }
        if task.state != .completed { try await transition(taskID, to: .queued, preparationEpoch: epoch) }
        else { try await store.ensureDownloadShelfOwner(for: task.chapter.id.sourceWorkID, expectedEpoch: epoch) }
    }
    public func retry(taskID: UUID, preparationEpoch: UUID? = nil) async throws { try await resume(taskID: taskID, preparationEpoch: preparationEpoch) }
    public func cancel(taskID: UUID) async throws { try await transition(taskID, to: .cancelled) }
    public func pause(sourceID: SourceID) async throws { for task in try await tasks() where task.chapter.id.sourceWorkID.sourceID == sourceID && [.running, .queued].contains(task.state) { try await pause(taskID: task.id) } }
    private func delete(_ tasks: [DownloadTask]) async throws {
        for task in tasks {
            queued.removeValue(forKey: task.id); tokens.removeValue(forKey: task.id); jobWorks.removeValue(forKey: task.id)
            jobs.removeValue(forKey: task.id)?.cancel()
        }
        let trash = offlineDirectory.appendingPathComponent(".removing/" + UUID().uuidString, isDirectory: true)
        var moved: [(URL, URL)] = []
        do {
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            for task in tasks {
                let original = folder(task.id), detached = trash.appendingPathComponent(task.id.uuidString, isDirectory: true)
                if FileManager.default.fileExists(atPath: original.path) { try FileManager.default.moveItem(at: original, to: detached); moved.append((original, detached)) }
            }
            try await store.deleteDownloads(taskIDs: Set(tasks.map(\.id)))
        } catch {
            for (original, detached) in moved.reversed() { try? FileManager.default.moveItem(at: detached, to: original) }
            try await store.pauseDownloads(taskIDs: Set(tasks.map(\.id)))
            throw error
        }
        let previous = cleanup
        cleanup = Task.detached(priority: .utility) { await previous?.value; try? FileManager.default.removeItem(at: trash) }
    }
    public func deleteDownloaded(chapterID: ChapterID) async throws {
        await startupRecovery.value
        try await delete(try await tasks().filter { $0.chapter.id == chapterID }); schedule()
    }
    public func deleteDownloaded(sourceWorkIDs: Set<SourceWorkID>) async throws {
        await startupRecovery.value
        removingWorks.formUnion(sourceWorkIDs)
        defer { removingWorks.subtract(sourceWorkIDs); schedule() }
        try await store.invalidateDownloadPreparations(for: sourceWorkIDs)
        try await delete(try await tasks().filter { sourceWorkIDs.contains($0.chapter.id.sourceWorkID) })
    }
    public func restore() async throws {
        await startupRecovery.value
        _ = try await transfer.recoverTransfers()
        for var task in try await tasks() where task.state != .cancelled {
            var manifest = try await store.offlineManifest(taskID: task.id) ?? OfflineManifest(taskID: task.id, chapterID: task.chapter.id)
            let before = manifest.entries.count; manifest.entries = manifest.entries.filter { valid($0, taskID: task.id) }
            task.completedPages = manifest.entries.count; task.bytes = manifest.entries.reduce(0) { $0 + $1.bytes }
            if task.state == .completed && (before != manifest.entries.count || manifest.entries.count != task.pages.count) { task.state = .failed; task.error = .invalidImage }
            if task.state == .failed, task.needsRefresh == true, task.refreshRequested != true, task.error == .accessRestricted(403), !requiresFreshPages(task) {
                let source = try await store.source(id: task.chapter.id.sourceWorkID.sourceID)
                if source?.enabled != false && source?.removed != true { task.state = .queued; task.error = nil }
            }
            if task.state == .running { task.state = .queued }
            // Public CDN addresses survive app restarts. Only temporary access
            // contexts and explicitly expired resources require a fresh chapter.
            if task.state == .queued { task.needsRefresh = task.refreshRequested == true || requiresFreshPages(task) }
            _ = try await store.saveDownload(task: task, manifest: manifest, expectedGeneration: task.generation); remember(task)
        }
        for task in try await tasks() {
            let hasContent = (try await store.offlineManifest(taskID: task.id)?.entries.isEmpty) == false
            if task.state != .cancelled || hasContent { try await store.ensureDownloadShelfOwner(for: task.chapter.id.sourceWorkID) }
        }
        schedule()
    }
    public func offlineManifest(chapterID: ChapterID) async throws -> (DownloadTask, OfflineManifest)? {
        guard let task = try await task(chapterID: chapterID), let manifest = try await store.offlineManifest(taskID: task.id) else { return nil }
        return (task, manifest)
    }
    public func offlineFiles(chapterID: ChapterID) async throws -> [PageID: URL] {
        await startupRecovery.value
        guard let (task, manifest) = try await offlineManifest(chapterID: chapterID), task.state == .completed, manifest.entries.count == task.pages.count, Set(manifest.entries.map(\.pageID)) == Set(task.pages.map(\.id)), manifest.entries.allSatisfy({ valid($0, taskID: task.id) }) else { throw MangaError.invalidImage }
        return Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.pageID, folder(task.id).appendingPathComponent($0.filename)) })
    }
    public func offlinePages(chapterID: ChapterID) async throws -> [URL] {
        let files = try await offlineFiles(chapterID: chapterID)
        guard let (task, _) = try await offlineManifest(chapterID: chapterID) else { throw MangaError.invalidImage }
        return try task.pages.sorted { $0.ordinal < $1.ordinal }.map { guard let file = files[$0.id] else { throw MangaError.invalidImage }; return file }
    }
}
