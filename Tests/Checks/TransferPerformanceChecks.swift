import Foundation
import MangaCore
import MangaPlatform

private actor MeasuredPageTransfer: PageTransferring {
    let data: Data
    var active = 0
    var peak = 0
    var calls = 0
    init(data: Data) { self.data = data }
    func download(_ request: ResourceRequest, sourceID: SourceID, taskID: UUID, to destination: URL) async throws -> TransferResult {
        active += 1; peak = max(peak, active); calls += 1
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(15)); try Task.checkCancellation()
        try data.write(to: destination)
        return TransferResult(file: destination, statusCode: 200, bytes: data.count)
    }
    func recoverTransfers() async throws -> [TransferRecord] { [] }
}
private func settledTransfer(_ manager: DownloadManager, _ id: UUID) async throws -> DownloadTask {
    for _ in 0..<1000 {
        if let value = try await manager.task(id: id), [.completed,.failed,.paused,.cancelled].contains(value.state) { return value }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CheckFailure(description: "Transfer failed to settle")
}
public let transferPerformanceChecks: [Check] = [
    Check("TransferPerformanceTests.failedRemovalLeavesRecoverablePausedTasks") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("db"))
        let manager = try DownloadManager(store: store, transfer: MeasuredPageTransfer(data: try generatedPNG()), verifier: ImageVerifier(), root: root)
        let chapter = Samples.chapter(Samples.work()); let task = DownloadTask(chapter: chapter, pages: Samples.pages(chapter), sourceSnapshot: nil)
        _ = try await store.saveDownload(task: task, manifest: OfflineManifest(taskID: task.id, chapterID: chapter.id))
        let trash = await manager.offlineDirectory.appendingPathComponent(".removing")
        try FileManager.default.removeItem(at: trash); try Data([1]).write(to: trash)
        do { try await manager.deleteDownloaded(sourceWorkIDs: [chapter.id.sourceWorkID]); throw CheckFailure(description: "Deletion should report the obstructed directory") }
        catch is CocoaError { }
        try expect(try await manager.task(id: task.id)?.state == .paused, "A failed deletion must not leave a phantom active task outside the scheduler")
    },
    Check("TransferPerformanceTests.restartRestoresUncommittedDeletionFolders") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("db"))
        let transfer = MeasuredPageTransfer(data: try generatedPNG())
        let manager = try DownloadManager(store: store, transfer: transfer, verifier: ImageVerifier(), root: root)
        let chapter = Samples.chapter(Samples.work()); let id = try await manager.enqueue(chapter: chapter, pages: Samples.pages(chapter))
        _ = try await settledTransfer(manager, id)
        let offline = await manager.offlineDirectory
        let detached = offline.appendingPathComponent(".removing/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: detached, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: offline.appendingPathComponent(id.uuidString), to: detached.appendingPathComponent(id.uuidString))
        let restarted = try DownloadManager(store: store, transfer: transfer, verifier: ImageVerifier(), root: root)
        try await restarted.restore()
        try expect(try await restarted.task(id: id)?.state == .completed, "Restart must roll back detached files if metadata deletion never committed")
        try expect(try await restarted.offlinePages(chapterID: chapter.id).count == 2, "An interrupted deletion cannot destroy still-recorded offline pages")
    },
    Check("TransferPerformanceTests.singleChapterUsesBoundedParallelImages") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("db"))
        let transfer = MeasuredPageTransfer(data: try generatedPNG())
        let manager = try DownloadManager(store: store, transfer: transfer, verifier: ImageVerifier(), root: root)
        let chapter = Samples.chapter(Samples.work()); let pages = Samples.pages(chapter, count: 12)
        let start = ContinuousClock.now
        let id = try await manager.enqueue(chapter: chapter, pages: pages)
        let done = try await settledTransfer(manager, id)
        print("MEASURE single-chapter-12-images \(start.duration(to: .now))")
        try expect(done.state == .completed && done.completedPages == 12, "Parallel transfer must complete every original page")
        let peak = await transfer.peak
        try expect(peak >= 3 && peak <= 6, "One chapter should overlap image requests within a bounded budget")
        let files = try await manager.offlinePages(chapterID: chapter.id)
        try expect(files.count == 12 && Set(files).count == 12, "Parallel completion preserves all page identities and offline ordering")
    },
    Check("TransferPerformanceTests.anotherWorkStartsBeforeTheFirstFinishes") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("db"))
        let manager = try DownloadManager(store: store, transfer: MeasuredPageTransfer(data: try generatedPNG()), verifier: ImageVerifier(), root: root)
        let a = Samples.work(), b = Samples.work(externalID: "another-work")
        var first: [UUID] = []
        for index in 0..<2 {
            let chapter = Samples.chapter(a, externalID: String(index), ordinal: index)
            first.append(try await manager.enqueue(chapter: chapter, pages: Samples.pages(chapter, count: 40)))
        }
        let chapter = Samples.chapter(b); let id = try await manager.enqueue(chapter: chapter, pages: Samples.pages(chapter, count: 2))
        let second = try await settledTransfer(manager, id)
        let overlapping = try await manager.task(id: first[0])
        try expect(second.state == .completed && overlapping?.state == .running, "A long first work must leave chapter capacity for a second work to download immediately")
        for id in first { try expect(try await settledTransfer(manager, id).state == .completed, "Sharing capacity cannot lose the first work's pages") }
    },
    Check("TransferPerformanceTests.parallelPauseResumeKeepsUniquePages") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("db"))
        let manager = try DownloadManager(store: store, transfer: MeasuredPageTransfer(data: try generatedPNG()), verifier: ImageVerifier(), root: root)
        let chapter = Samples.chapter(Samples.work()); let pages = Samples.pages(chapter, count: 15)
        let id = try await manager.enqueue(chapter: chapter, pages: pages)
        for _ in 0..<200 { if try await manager.task(id: id)?.completedPages ?? 0 > 0 { break }; try await Task.sleep(for: .milliseconds(1)) }
        try await manager.pause(taskID: id)
        let paused = try await manager.task(id: id)!
        try expect(paused.state == .paused && paused.completedPages > 0, "Pause checkpoints already received pages while cancelling parallel requests")
        try await manager.resume(taskID: id)
        let done = try await settledTransfer(manager, id)
        let manifest = try await store.offlineManifest(taskID: id)!
        try expect(done.state == .completed && Set(manifest.entries.map(\.pageID)).count == 15 && manifest.entries.count == 15, "Late cancelled workers cannot duplicate pages or overwrite resumed progress")
        try expect(try await manager.offlinePages(chapterID: chapter.id).count == 15, "Every completed entry remains readable after parallel resume")
    },
    Check("TransferPerformanceTests.bulkRemovalReclaimsDetachedFiles") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("db"))
        let manager = try DownloadManager(store: store, transfer: MeasuredPageTransfer(data: try generatedPNG()), verifier: ImageVerifier(), root: root)
        let work = Samples.work(); let offline = await manager.offlineDirectory
        var folders: [URL] = []
        for index in 0..<16 {
            let chapter = Samples.chapter(work, externalID: String(index), ordinal: index)
            var task = DownloadTask(chapter: chapter, pages: Samples.pages(chapter), sourceSnapshot: nil); task.state = .paused
            _ = try await store.saveDownload(task: task, manifest: OfflineManifest(taskID: task.id, chapterID: chapter.id))
            let directory = offline.appendingPathComponent(task.id.uuidString); folders.append(directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for page in 0..<64 { try Data(repeating: 7, count: 1024).write(to: directory.appendingPathComponent(String(page))) }
        }
        let start = ContinuousClock.now
        try await manager.deleteDownloaded(sourceWorkIDs: [work.id])
        print("MEASURE detach-1024-offline-files \(start.duration(to: .now))")
        try expect(folders.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "Removed offline paths disappear before the shelf operation completes")
        let trash = offline.appendingPathComponent(".removing")
        for _ in 0..<1000 {
            if try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty, "Background deletion really reclaims all detached files")
    },
    Check("TransferPerformanceTests.bulkRemovalNeverSchedulesRemovedChapters") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("db"))
        let transfer = MeasuredPageTransfer(data: try generatedPNG())
        let manager = try DownloadManager(store: store, transfer: transfer, verifier: ImageVerifier(), root: root)
        let work = Samples.work()
        for index in 0..<120 {
            let chapter = Samples.chapter(work, externalID: String(index), ordinal: index)
            let task = DownloadTask(chapter: chapter, pages: Samples.pages(chapter), sourceSnapshot: nil)
            _ = try await store.saveDownload(task: task, manifest: OfflineManifest(taskID: task.id, chapterID: chapter.id))
        }
        let start = ContinuousClock.now
        try await manager.deleteDownloaded(sourceWorkIDs: [work.id])
        print("MEASURE remove-120-chapters \(start.duration(to: .now))")
        try expect(try await manager.tasks().isEmpty, "All selected task and manifest metadata must be removed")
        try expect(await transfer.calls == 0, "Bulk removal must not repeatedly reschedule chapters it is about to remove")
    }
]
