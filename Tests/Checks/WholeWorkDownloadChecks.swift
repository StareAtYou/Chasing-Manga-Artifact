import Foundation
import MangaCore
import MangaPlatform
import MangaUI
actor WholeDownloadState {
    var restricted = false
    var fails = false
    var blocked = false
    var blockedAfterFirst = false
    var detailCalls = 0
    var requests:[ChapterID] = []
    var gates:[CheckedContinuation<Void,Never>] = []
    func configure(restricted:Bool=false,fails:Bool=false,blocked:Bool=false,blockedAfterFirst:Bool=false) {self.restricted=restricted;self.fails=fails;self.blocked=blocked;self.blockedAfterFirst=blockedAfterFirst}
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
        if blocked || (blockedAfterFirst && chapter.ordinal > 0) {await withCheckedContinuation {gates.append($0)}}
        try Task.checkCancellation()
        if fails,chapter.ordinal == 2 {throw MangaError.parseMismatch("单章样本故障")}
        return Samples.pages(chapter)
    }
    func release() {blocked=false;blockedAfterFirst=false;let pending=gates;gates=[];for gate in pending {gate.resume()}}
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
private struct MultiWorkDownloadAdapter:SourceAdapter {
    let blocked:WholeDownloadState
    let other:WholeDownloadState
    let id="multi-work-download-fixture"
    let version=1
    let capabilities:SourceCapabilities = [.readable]
    private func state(_ sourceID:SourceID)->WholeDownloadState {sourceID == Samples.sourceA.id ? blocked : other}
    func details(url:URL,context:ParserContext) async throws -> SourceWork {await state(context.source.id).details();return Samples.work(context.source)}
    func chapters(work:SourceWork,context:ParserContext) async throws -> [Chapter] {await state(context.source.id).catalogue(work)}
    func pages(chapter:Chapter,context:ParserContext) async throws -> [PageResource] {try await state(context.source.id).read(chapter)}
}
func wholeFixture(_ root:URL,state:WholeDownloadState,transfer:(any PageTransferring)?=nil) async throws -> (AppContainer,SourceWork) {
    let app=try await MainActor.run {try AppContainer(root:root,client:FixtureHTTPClient([:]),registry:ParserRegistry(adapters:[WholeDownloadAdapter(state:state)]),transfer:transfer ?? FixtureTransfer(data:try generatedPNG()))}
    var source=Samples.sourceA;source.binding=ParserBinding(parserID:"whole-download-fixture")
    try await app.store.save(source:source)
    let work=Samples.work(source)
    try await app.store.save(sourceWork:work,chapters:[Samples.chapter(work)])
    await app.start(registerBuiltins:false)
    return (app,work)
}
private func multiWholeFixture(_ root:URL,blocked:WholeDownloadState,other:WholeDownloadState) async throws -> (AppContainer,SourceWork,SourceWork) {
    let app=try await MainActor.run {try AppContainer(root:root,client:FixtureHTTPClient([:]),registry:ParserRegistry(adapters:[MultiWorkDownloadAdapter(blocked:blocked,other:other)]),transfer:FixtureTransfer(data:try generatedPNG()))}
    var sourceA=Samples.sourceA;sourceA.binding=ParserBinding(parserID:"multi-work-download-fixture")
    var sourceB=Samples.sourceB;sourceB.binding=ParserBinding(parserID:"multi-work-download-fixture")
    try await app.store.save(source:sourceA);try await app.store.save(source:sourceB)
    let workA=Samples.work(sourceA),workB=Samples.work(sourceB)
    try await app.store.save(sourceWork:workA,chapters:[Samples.chapter(workA)])
    try await app.store.save(sourceWork:workB,chapters:[Samples.chapter(workB)])
    await app.start(registerBuiltins:false)
    return (app,workA,workB)
}
private func settleWhole(_ app:AppContainer) async throws {
    for _ in 0..<100_000 {
        if await !app.preparingBatch {return}
        await Task.yield()
    }
    throw CheckFailure(description:"Whole work preparation did not settle")
}
public let wholeWorkDownloadChecks:[Check] = [
    Check("WholeWorkDownloadTests.firstQueuedChapterPublishesShelfBeforePreparationFinishes") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let state=WholeDownloadState();await state.configure(blockedAfterFirst:true)
        let (app,work)=try await wholeFixture(root,state:state)
        let grouped=try await app.store.createWork(from:work.id,onShelf:false)
        try await app.refresh()
        try expect(await app.library.isEmpty,"Discovery work starts outside the shelf")
        await app.startWholeDownload(work.id)
        for _ in 0..<100_000 {
            let visible=await MainActor.run {app.library.contains {$0.id == grouped.id} && app.workSourceIDs[grouped.id]?.contains(work.id) == true}
            if visible {break}
            await Task.yield()
        }
        let duringPreparation=await MainActor.run {
            app.isPreparingDownloads(for:work.id) && app.library.contains {$0.id == grouped.id}
                && app.workSourceIDs[grouped.id]?.contains(work.id) == true
        }
        let queuedBeforeRelease=try await app.downloads.tasks().count
        await state.release();try await settleWhole(app)
        let tasks=try await app.downloads.tasks()
        for task in tasks {_ = try await waitForDownload(app.downloads,task.id)}
        await app.updateScheduler.stop()
        try expect(queuedBeforeRelease == 1,"Hold later chapter parsing while the first chapter has entered the real queue")
        try expect(duringPreparation,"First queued chapter must publish the discovery work and its source IDs to the shelf before the long preparation finishes")
        try expect(tasks.count == 4,"Early shelf publication preserves the rest of whole-work preparation")
    },
    Check("WholeWorkDownloadTests.blockedWorkDoesNotPreventAnotherWorkPreparation") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let blocked=WholeDownloadState();await blocked.configure(blocked:true)
        let other=WholeDownloadState()
        let (app,workA,workB)=try await multiWholeFixture(root,blocked:blocked,other:other)
        await app.startWholeDownload(workA.id)
        for _ in 0..<100_000 {if await !blocked.requests.isEmpty {break};await Task.yield()}
        await app.queueWholeWork(workB.id)
        let otherTasks=try await app.downloads.tasks().filter {$0.chapter.id.sourceWorkID == workB.id}
        let independentStatus=await MainActor.run {
            app.isPreparingDownloads(for:workA.id) && !app.isPreparingDownloads(for:workB.id)
                && app.downloadPreparations[workA.id]?.finished == 0 && app.downloadPreparations[workB.id]?.finished == 4
        }
        await app.cancelPreparation();await blocked.release();try await settleWhole(app)
        for task in try await app.downloads.tasks() {_ = try await waitForDownload(app.downloads,task.id)}
        await app.updateScheduler.stop()
        try expect(otherTasks.count == 4,"A stalled work must not prevent another work from preparing its complete download queue")
        try expect(independentStatus,"A second work keeps its own progress without resetting or finishing the stalled work's status")
    },
    Check("WholeWorkDownloadTests.removingOneWorkCancelsOnlyItsPreparation") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let stateA=WholeDownloadState(),stateB=WholeDownloadState()
        await stateA.configure(blocked:true);await stateB.configure(blocked:true)
        let (app,workA,workB)=try await multiWholeFixture(root,blocked:stateA,other:stateB)
        let groupedA=try await app.store.createWork(from:workA.id)
        await MainActor.run { app.startWholeDownload(workA.id);app.startWholeDownload(workB.id) }
        for _ in 0..<100_000 {
            let startedA=await !stateA.requests.isEmpty,startedB=await !stateB.requests.isEmpty
            if startedA && startedB {break}
            await Task.yield()
        }
        await app.removeFromShelf(groupedA.id)
        let otherUncancelled=await MainActor.run {app.downloadPreparations[workB.id]?.cancelled == false}
        await stateA.release();await stateB.release();try await settleWhole(app)
        let tasks=try await app.downloads.tasks()
        let status=await MainActor.run {(app.downloadPreparations[workA.id]?.cancelled,app.downloadPreparations[workB.id]?.finished)}
        for task in tasks {_ = try await waitForDownload(app.downloads,task.id)}
        await app.updateScheduler.stop()
        try expect(otherUncancelled && tasks.count == 4 && tasks.allSatisfy{$0.chapter.id.sourceWorkID == workB.id},"Removing a shelf work cancels only its own suspended preparation and permits the other work to finish")
        try expect(status.0 == true && status.1 == 4,"Cancellation and completed chapter counts remain scoped to each work")
    },
    Check("WholeWorkDownloadTests.preparesTwoChaptersConcurrentlyWithBoundedFanout") {
        let root=try Samples.temporaryDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let state=WholeDownloadState();await state.configure(blocked:true)
        let (app,work)=try await wholeFixture(root,state:state)
        await app.startWholeDownload(work.id)
        for _ in 0..<100_000 {if await state.requests.count >= 2 {break};await Task.yield()}
        let inFlight=await state.requests.count
        await app.cancelPreparation();await state.release();try await settleWhole(app)
        await app.updateScheduler.stop()
        try expect(inFlight == 2,"Prepare two chapter page lists concurrently and keep later chapters pending while both slots are occupied")
        try expect(try await app.downloads.tasks().isEmpty,"Cancelled concurrent chapter preparation cannot enqueue stale results")
    },
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
