import Foundation
import MangaCore
import MangaPlatform
import MangaUI
private actor ShelfGatedTransfer: PageTransferring {
    let data:Data
    var started=false
    var pending:[CheckedContinuation<Void,Never>]=[]
    init(_ data:Data) {self.data=data}
    func download(_ request:ResourceRequest,sourceID:SourceID,taskID:UUID,to destination:URL) async throws -> TransferResult {
        started=true;await withCheckedContinuation {pending.append($0)}
        try Task.checkCancellation();try data.write(to:destination)
        return TransferResult(file:destination,statusCode:200,bytes:data.count)
    }
    func release() {let gates=pending;pending=[];for gate in gates {gate.resume()}}
    func recoverTransfers() async throws -> [TransferRecord] {[]}
}
public let shelfDownloadChecks:[Check] = [
    Check("ShelfDownloadTests.singleDownloadAddsExistingGroupWithoutFollowing") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let (app,work)=try await wholeFixture(root,state:WholeDownloadState())
        let owner=try await app.store.createWork(from:work.id,onShelf:false)
        try await app.queueDownload(Samples.chapter(work))
        let tasks=try await app.downloads.tasks();for t in tasks {_ = try await waitForDownload(app.downloads,t.id)}
        let shelf=try await app.store.library();let followed=try await app.updates.followedIDs()
        try expect(shelf.map(\.id)==[owner.id],"A queued chapter brings its existing grouped work onto the shelf")
        try expect(followed.isEmpty,"Automatic shelf ownership must not enable update following")
        await app.queueWholeWork(work.id)
        try expect(try await app.store.library().count == 1,"Whole download reuses the same shelf card")
        for t in try await app.downloads.tasks() {_ = try await waitForDownload(app.downloads,t.id)}
        await app.updateScheduler.stop()
    },
    Check("ShelfDownloadTests.removalDeletesAllLinkedDownloadsAndKeepsOtherWorks") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let (app,work)=try await wholeFixture(root,state:WholeDownloadState())
        let owner=try await app.store.createWork(from:work.id)
        var otherSource=Samples.sourceB;otherSource.binding=ParserBinding(parserID:"whole-download-fixture");try await app.store.save(source:otherSource)
        let linked=Samples.work(otherSource);let linkedChapter=Samples.chapter(linked);try await app.store.save(sourceWork:linked,chapters:[linkedChapter]);try await app.store.link(linked.id,to:owner.id)
        let unrelated=Samples.work(otherSource,externalID:"separate");let unrelatedChapter=Samples.chapter(unrelated)
        try await app.store.save(sourceWork:unrelated,chapters:[unrelatedChapter]);let otherOwner=try await app.store.createWork(from:unrelated.id)
        let chapter=Samples.chapter(work)
        for c in [chapter,linkedChapter,unrelatedChapter] {
            let tid=try await app.downloads.enqueue(chapter:c,pages:Samples.pages(c));_ = try await waitForDownload(app.downloads,tid)
        }
        let before=try await app.downloads.tasks();let removed=before.filter{$0.chapter.id.sourceWorkID != unrelated.id}
        let progress=ReadingProgress(chapterID:chapter.id,pageID:Samples.pages(chapter)[0].id)
        try await app.store.save(progress:progress)
        await app.removeFromShelf(owner.id)
        let after=try await app.downloads.tasks()
        try expect(after.count == 1 && after[0].chapter.id.sourceWorkID == unrelated.id,"Removing a work clears every linked source but preserves unrelated downloads")
        for t in removed {
            try expect(try await app.store.offlineManifest(taskID:t.id)==nil,"Removed task manifests are deleted")
            let folder=await app.downloads.offlineDirectory.appendingPathComponent(t.id.uuidString)
            try expect(!FileManager.default.fileExists(atPath:folder.path),"Removed task folders are deleted")
        }
        try expect(try await app.store.library().map(\.id)==[otherOwner.id],"Only the requested work leaves the shelf")
        try expect(try await app.store.progress(for:work.id) != nil,"Reading progress survives shelf removal")
        try expect(try await app.downloads.offlinePages(chapterID:unrelatedChapter.id).count==2,"Other work remains readable offline")
        await app.updateScheduler.stop()
    },
    Check("ShelfDownloadTests.removalRejectsSuspendedPreparationThenAllowsNewDownload") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let state=WholeDownloadState();await state.configure(blocked:true)
        let (app,work)=try await wholeFixture(root,state:state);let owner=try await app.store.createWork(from:work.id)
        let preparing=Task {await app.queueWholeWork(work.id)}
        for _ in 0..<100_000 {if await !state.requests.isEmpty {break};await Task.yield()}
        await app.removeFromShelf(owner.id);await state.release();await preparing.value
        try expect(try await app.downloads.tasks().isEmpty,"Older suspended preparation cannot enqueue after shelf removal")
        try expect(try await app.store.library().isEmpty,"Older preparation cannot recreate the removed shelf card")
        await app.queueWholeWork(work.id)
        let tasks=try await app.downloads.tasks();let shelf=try await app.store.library();try expect(tasks.count==4 && shelf.count==1,"A new explicit download can re-add the work")
        for t in tasks {_ = try await waitForDownload(app.downloads,t.id)}
        await app.updateScheduler.stop()
    },
    Check("ShelfDownloadTests.removalCancelsInFlightImageTransfer") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let transfer=ShelfGatedTransfer(try generatedPNG())
        let (app,work)=try await wholeFixture(root,state:WholeDownloadState(),transfer:transfer)
        let owner=try await app.store.createWork(from:work.id)
        let id=try await app.downloads.enqueue(chapter:Samples.chapter(work),pages:Samples.pages(Samples.chapter(work)))
        for _ in 0..<100_000 {if await transfer.started {break};await Task.yield()}
        await app.removeFromShelf(owner.id);await transfer.release()
        for _ in 0..<100 {await Task.yield()}
        try expect(try await app.downloads.tasks().isEmpty,"Removing a work cancels its in-flight image task")
        let folder=await app.downloads.offlineDirectory.appendingPathComponent(id.uuidString)
        try expect(!FileManager.default.fileExists(atPath:folder.path),"Cancelled transfer cannot recreate the deleted offline folder")
        await app.updateScheduler.stop()
    },
    Check("ShelfDownloadTests.legacyDisabledSourceDownloadReturnsToShelf") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let (app,work)=try await wholeFixture(root,state:WholeDownloadState());let owner=try await app.store.createWork(from:work.id,onShelf:false)
        let chapter=Samples.chapter(work);let tid=try await app.downloads.enqueue(chapter:chapter,pages:Samples.pages(chapter));_ = try await waitForDownload(app.downloads,tid)
        try await app.store.setOnShelf(false,workID:owner.id);try await app.store.setSourceEnabled(false,id:work.id.sourceID)
        try await app.downloads.restore()
        try expect(try await app.store.library().map(\.id)==[owner.id],"Legacy completed downloads get a shelf owner even when the source is disabled")
        try expect(try await app.downloads.offlinePages(chapterID:chapter.id).count==2,"Migration keeps existing offline images")
        await app.updateScheduler.stop()
    }
]
