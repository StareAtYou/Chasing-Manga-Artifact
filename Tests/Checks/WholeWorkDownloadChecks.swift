import Foundation
import MangaCore
import MangaPlatform
import MangaUI
private actor WholeDownloadState {
    var restricted = false
    var fails = false
    var blocked = false
    var detailCalls = 0
    var requests:[ChapterID] = []
    var gates:[CheckedContinuation<Void,Never>] = []
    func configure(restricted:Bool=false,fails:Bool=false,blocked:Bool=false) {self.restricted=restricted;self.fails=fails;self.blocked=blocked}
    func details() {detailCalls += 1}
    func catalogue(_ work:SourceWork) -> [Chapter] {
        (0..<4).map {index in
            var chapter=Samples.chapter(work,externalID:String(index+1),ordinal:index)
            if restricted,index == 1 {chapter.access = .paid}
            return chapter
        }
    }
    func read(_ chapter:Chapter) async throws -> [PageResource] {
        requests.append(chapter.id)
        if blocked {await withCheckedContinuation {gates.append($0)}}
        try Task.checkCancellation()
        if fails,chapter.ordinal == 2 {throw MangaError.parseMismatch("单章样本故障")}
        return Samples.pages(chapter)
    }
    func release() {blocked=false;let pending=gates;gates=[];for gate in pending {gate.resume()}}
}
private struct WholeDownloadAdapter:SourceAdapter {
    let state:WholeDownloadState
    let id="whole-download-fixture"
    let version=1
    let capabilities:SourceCapabilities = [.readable]
    func details(url:URL,context:ParserContext) async throws -> SourceWork {await state.details();return Samples.work(context.source)}
    func chapters(work:SourceWork,context:ParserContext) async throws -> [Chapter] {await state.catalogue(work)}
    func pages(chapter:Chapter,context:ParserContext) async throws -> [PageResource] {try await state.read(chapter)}
}
private func wholeFixture(_ root:URL,state:WholeDownloadState) async throws -> (AppContainer,SourceWork) {
    let app=try await MainActor.run {try AppContainer(root:root,client:FixtureHTTPClient([:]),registry:ParserRegistry(adapters:[WholeDownloadAdapter(state:state)]),transfer:FixtureTransfer(data:try generatedPNG()))}
    var source=Samples.sourceA;source.binding=ParserBinding(parserID:"whole-download-fixture")
    try await app.store.save(source:source)
    let work=Samples.work(source)
    try await app.store.save(sourceWork:work,chapters:[Samples.chapter(work)])
    await app.start(registerBuiltins:false)
    return (app,work)
}
private func settleWhole(_ app:AppContainer) async throws {
    for _ in 0..<100_000 {
        if await !app.preparingBatch {return}
        await Task.yield()
    }
    throw CheckFailure(description:"Whole work preparation did not settle")
}
public let wholeWorkDownloadChecks:[Check] = [
    Check("WholeWorkDownloadTests.refreshesCompleteDirectoryAndCreatesOfflineChapters") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let state=WholeDownloadState();let (app,work)=try await wholeFixture(root,state:state)
        await app.queueWholeWork(work.id)
        let tasks=try await app.downloads.tasks()
        try expect(tasks.count == 4 && tasks.allSatisfy{$0.chapter.id.sourceWorkID == work.id},"Download the complete fresh directory, not the stale saved chapter list")
        for task in tasks {_ = try await waitForDownload(app.downloads,task.id);try expect(try await app.downloads.offlinePages(chapterID:task.chapter.id).count == 2,"Each chapter remains readable offline")}
        await app.updateScheduler.stop()
    },
    Check("WholeWorkDownloadTests.skipsPaidContinuesFailureAndRetriesWithoutDuplicates") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let state=WholeDownloadState();await state.configure(restricted:true,fails:true)
        let (app,work)=try await wholeFixture(root,state:state)
        await app.queueWholeWork(work.id)
        let initial=try await app.downloads.tasks();for task in initial {_ = try await waitForDownload(app.downloads,task.id)}
        try expect(initial.count == 2 && initial.map{$0.chapter.ordinal}.sorted() == [0,3],"Skip paid chapter and continue beyond one chapter parsing failure")
        let status=await MainActor.run {(app.preparationErrors.count,app.preparationSkipped)}
        try expect(status.0 == 1 && status.1 == 1,"Report unavailable chapters separately from preparation errors")
        let failedChapter=Samples.chapter(work,externalID:"3",ordinal:2)
        let failedTitle=await app.chapterTitle(failedChapter.id)
        try expect(failedTitle == failedChapter.title,"Identify a failed new chapter by its title even without history or a download task")
        await state.configure(restricted:true)
        await app.queueWholeWork(work.id)
        let retried=try await app.downloads.tasks();for task in retried {_ = try await waitForDownload(app.downloads,task.id)}
        try expect(retried.count == 3 && Set(initial.map(\.id)).isSubset(of:Set(retried.map(\.id))),"Retry missing chapter and preserve all completed task identities")
        await app.updateScheduler.stop()
    },
    Check("WholeWorkDownloadTests.keepsOtherAssociatedSourceOutOfQueue") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let state=WholeDownloadState();let (app,work)=try await wholeFixture(root,state:state)
        var other=Samples.sourceB;other.binding=ParserBinding(parserID:"whole-download-fixture");try await app.store.save(source:other)
        let otherWork=Samples.work(other);try await app.store.save(sourceWork:otherWork,chapters:[Samples.chapter(otherWork)])
        let grouped=try await app.store.createWork(from:work.id);try await app.store.link(otherWork.id,to:grouped.id)
        await app.queueWholeWork(work.id)
        let tasks=try await app.downloads.tasks()
        try expect(tasks.count == 4 && tasks.allSatisfy{$0.chapter.id.sourceWorkID == work.id},"Explicit source selection never merges chapters from an associated source")
        for task in tasks {_ = try await waitForDownload(app.downloads,task.id)}
        await app.updateScheduler.stop()
    },
    Check("WholeWorkDownloadTests.doubleTapReservedAndCancellationStopsPreparation") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let state=WholeDownloadState();await state.configure(blocked:true)
        let (app,work)=try await wholeFixture(root,state:state)
        await MainActor.run {app.startWholeDownload(work.id);app.startWholeDownload(work.id)}
        for _ in 0..<100_000 {if await !state.requests.isEmpty {break};await Task.yield()}
        let calls=await state.detailCalls
        try expect(calls == 1,"Reserve batch immediately so a double tap refreshes the directory only once")
        await app.cancelPreparation();await state.release();try await settleWhole(app)
        try expect(try await app.downloads.tasks().isEmpty,"Cancelled preparation must not enqueue the in-flight chapter or subsequent ones")
        await app.queueWholeWork(work.id)
        let tasks=try await app.downloads.tasks();try expect(tasks.count == 4,"Clicking whole download again fills remaining chapters")
        for task in tasks {_ = try await waitForDownload(app.downloads,task.id)}
        await app.updateScheduler.stop()
    },
    Check("WholeWorkDownloadTests.resumesPausedAndFailedTasksUsingOriginalIdentities") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let state=WholeDownloadState();let (app,work)=try await wholeFixture(root,state:state)
        var originals:[DownloadTask]=[]
        for index in 0..<2 {
            let chapter=Samples.chapter(work,externalID:String(index+1),ordinal:index)
            var task=DownloadTask(chapter:chapter,pages:Samples.pages(chapter),sourceSnapshot:try await app.store.source(id:work.id.sourceID))
            task.state=index == 0 ? .paused : .failed
            _ = try await app.store.saveDownload(task:task,manifest:OfflineManifest(taskID:task.id,chapterID:chapter.id))
            originals.append(task)
        }
        await app.queueWholeWork(work.id)
        let tasks=try await app.downloads.tasks()
        try expect(tasks.count == 4 && Set(originals.map(\.id)).isSubset(of:Set(tasks.map(\.id))),"Resume paused and failed chapters without creating replacement tasks")
        for task in tasks {_ = try await waitForDownload(app.downloads,task.id);try expect(try await app.downloads.offlinePages(chapterID:task.chapter.id).count == 2,"Resumed chapters become readable offline")}
        await app.updateScheduler.stop()
    },
    Check("WholeWorkDownloadTests.disabledSourceFailsWithoutChangingOfflineData") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let state=WholeDownloadState();let (app,work)=try await wholeFixture(root,state:state)
        try await app.store.setSourceEnabled(false,id:work.id.sourceID)
        await app.queueWholeWork(work.id)
        let tasks=try await app.downloads.tasks();let message=await app.message
        let calls=await state.detailCalls
        try expect(tasks.isEmpty && message != nil && calls == 0,"Stopped sources fail clearly without requesting their catalogue")
        await app.updateScheduler.stop()
    }
]
