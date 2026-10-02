import Foundation
import MangaCore
import MangaPlatform
public actor FixtureTransfer: PageTransferring {
    let data: Data
    var calls: [URL] = []
    var failAfter: Int?
    var diskFull = false
    public init(data: Data, failAfter: Int? = nil) { self.data = data; self.failAfter = failAfter }
    public func setDiskFull() { diskFull = true }
    public func download(_ request: ResourceRequest, sourceID: SourceID, taskID: UUID, to: URL) async throws -> TransferResult {
        try Task.checkCancellation()
        if diskFull { throw MangaError.diskFull }
        if let failAfter, calls.count >= failAfter { throw MangaError.networkUnavailable }
        calls.append(request.url); try data.write(to: to, options: .atomic)
        return TransferResult(file: to, statusCode: 200, bytes: data.count)
    }
    public func recoverTransfers() async throws -> [TransferRecord] { [] }
}
func waitForDownload(_ manager: DownloadManager, _ id: UUID) async throws -> DownloadTask {
    for _ in 0..<10_000 {
        if let task = try await manager.task(id: id), [.completed, .failed, .paused, .cancelled].contains(task.state) { return task }
        await Task.yield()
    }
    throw CheckFailure(description: "Download never reached a terminal or paused state")
}
public let downloadManagerChecks: [Check] = [
    Check("DownloadManagerTests.restartWithNewSignatureKeepsCompletedPages") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite")); try await store.save(source: Samples.sourceA)
        let chapter = Samples.chapter(Samples.work()); let pages = Samples.pages(chapter, count: 3)
        let first = FixtureTransfer(data: try generatedPNG(), failAfter: 1)
        let manager = try DownloadManager(store: store, transfer: first, verifier: ImageVerifier(), root: directory)
        let id = try await manager.enqueue(chapter: chapter, pages: pages); let failed = try await waitForDownload(manager, id)
        try expect(failed.state == .failed && failed.completedPages == 1, "Retain complete pages after interrupted transfer")
        let second = FixtureTransfer(data: try generatedPNG())
        let restarted = try DownloadManager(store: store, transfer: second, verifier: ImageVerifier(), root: directory, refresh: { _ in pages.map { page in var value = page; value.request.url = value.request.url.appending(queryItems: [URLQueryItem(name: "sign", value: "new")]); return value } })
        try await restarted.restore(); try await restarted.retry(taskID: id)
        let finished = try await waitForDownload(restarted, id)
        let calls = await second.calls.count
        try expect(finished.state == .completed && calls == 2, "After restart download missing pages only")
    },
    Check("DownloadManagerTests.missingOrCorruptPageIsNotComplete") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite")); let chapter = Samples.chapter(Samples.work())
        let manager = try DownloadManager(store: store, transfer: FixtureTransfer(data: try generatedPNG()), verifier: ImageVerifier(), root: directory)
        let id = try await manager.enqueue(chapter: chapter, pages: Samples.pages(chapter)); _ = try await waitForDownload(manager, id)
        let files = try await manager.offlinePages(chapterID: chapter.id); try Data("corrupt".utf8).write(to: files[0])
        try await manager.restore()
        try expect(try await manager.task(id: id)?.state != .completed, "Corrupt file invalidates completion")
        do { _ = try await manager.offlinePages(chapterID: chapter.id); throw CheckFailure(description: "Cannot read corrupt manifest") } catch MangaError.invalidImage { }
    },
    Check("DownloadManagerTests.clearCachePreservesOfflineChapter") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite")); let chapter = Samples.chapter(Samples.work())
        let manager = try DownloadManager(store: store, transfer: FixtureTransfer(data: try generatedPNG()), verifier: ImageVerifier(), root: directory)
        let id = try await manager.enqueue(chapter: chapter, pages: Samples.pages(chapter)); _ = try await waitForDownload(manager, id)
        let cache = try PageFileStore(root: directory); _ = try await cache.writeCache(data: generatedPNG(), pageID: Samples.pages(chapter)[0].id); try await cache.clearCache()
        try expect(try await manager.offlinePages(chapterID: chapter.id).count == 2, "Automatic cache and offline files are independent")
    },
    Check("DownloadManagerTests.diskFullPausesWithoutDeletingDownloads") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite")); let chapter = Samples.chapter(Samples.work())
        let transfer = FixtureTransfer(data: try generatedPNG()); let manager = try DownloadManager(store: store, transfer: transfer, verifier: ImageVerifier(), root: directory)
        let done = try await manager.enqueue(chapter: chapter, pages: Samples.pages(chapter)); _ = try await waitForDownload(manager, done)
        await transfer.setDiskFull(); let next = Samples.chapter(Samples.work(), externalID: "2")
        let id = try await manager.enqueue(chapter: next, pages: Samples.pages(next)); let task = try await waitForDownload(manager, id)
        try expect(task.state == .paused && task.error == .diskFull, "Disk full pauses")
        try expect(try await manager.offlinePages(chapterID: chapter.id).count == 2, "Existing downloads retained")
    },
    Check("DownloadManagerTests.removedSourceStillReadsOffline") {
        let directory = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(databaseURL: directory.appendingPathComponent("db.sqlite")); try await store.save(source: Samples.sourceA)
        let chapter = Samples.chapter(Samples.work()); let manager = try DownloadManager(store: store, transfer: FixtureTransfer(data: try generatedPNG()), verifier: ImageVerifier(), root: directory)
        let id = try await manager.enqueue(chapter: chapter, pages: Samples.pages(chapter)); _ = try await waitForDownload(manager, id); try await store.remove(sourceID: Samples.sourceA.id)
        try expect(try await manager.offlinePages(chapterID: chapter.id).count == 2, "Offline reader does not depend on live source")
    }
]
