import Foundation
import MangaCore
import MangaUI

public let sourceReadingChecks: [Check] = [
    Check("SourceReadingTests.discoverySelectsNamedSourceWithoutChangingAssociations") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root)
        let sources = try await app.store.allSourceWorks(); let first = sources[0]; let selected = sources[1]
        let group = try await app.store.workID(for: first.id)!
        try await app.store.link(selected.id, to: group)
        await app.select(selected)
        let saved = try await app.store.work(id: group)
        try expect(saved?.preferredSourceWorkID == selected.id, "Opening a discovery result automatically selects its named source")
        try expect(try await app.store.sourceWorks(for: group).count == 2, "Selecting a result preserves existing associations")
        try expect(await app.path.last == .work(group), "Discovery still opens the work detail")
        await app.updateScheduler.stop()
    },
    Check("SourceReadingTests.cardStartsFirstAvailableChapterAndKeepsDirectoryExplicit") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root)
        let source = try await app.store.allSourceWorks()[0]; let group = try await app.store.workID(for: source.id)!
        var chapters = try await app.store.chapters(for: source.id)
        chapters[0].access = .paid
        try await app.store.save(sourceWork: source, chapters: chapters)
        await app.openSource(source.id, for: group)
        try expect(await app.path == [.reader(chapters[1].id)], "Card skips locked chapters and enters the first readable chapter directly")
        await app.chooseSource(source.id, for: group)
        try expect(await app.path.last == .chapters(source.id), "The separate directory action remains available")
        await app.updateScheduler.stop()
    },
    Check("SourceReadingTests.cardResumesOnlyTappedSourceProgress") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root)
        let sources = try await app.store.allSourceWorks(); let group = try await app.store.workID(for: sources[0].id)!
        try await app.store.link(sources[1].id, to: group)
        let first = try await app.store.chapters(for: sources[0].id)[1]
        let selected = try await app.store.chapters(for: sources[1].id)[1]
        let otherProgress = ReadingProgress(chapterID: first.id, pageID: PageID(chapterID: first.id, externalID: "2"), fraction: 0.6)
        let selectedProgress = ReadingProgress(chapterID: selected.id, pageID: PageID(chapterID: selected.id, externalID: "1"), fraction: 0.25)
        try await app.store.save(progress: otherProgress); try await app.store.save(progress: selectedProgress)
        await app.openSource(sources[1].id, for: group)
        try expect(await app.path == [.reader(selected.id)], "Tap resumes this source even when another associated source has progress")
        try expect(try await app.store.progress(for: sources[0].id) == otherProgress, "Opening a source preserves other-source progress")
        try expect(try await app.store.progress(for: sources[1].id) == selectedProgress, "Opening retains this source's page and fraction")
        try expect(try await app.store.work(id: group)?.preferredSourceWorkID == sources[1].id, "Reading remembers the tapped source")
        await app.updateScheduler.stop()
    },
    Check("SourceReadingTests.cardLoadsMissingDirectory") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root)
        let original = try await app.store.allSourceWorks()[0]
        let work = SourceWork(id: SourceWorkID(sourceID: original.id.sourceID, externalID: "stars"), title: "星际来信", url: original.url.deletingLastPathComponent().appendingPathComponent("stars"))
        try await app.store.save(sourceWork: work, chapters: [])
        let group = try await app.store.createWork(from: work.id, onShelf: false)
        await app.openSource(work.id, for: group.id)
        let chapters = try await app.store.chapters(for: work.id)
        let route = await app.path.last
        try expect(chapters.count == 2 && route == .reader(ChapterID(sourceWorkID: work.id, externalID: "0")), "Card loads a missing online directory before entering its first chapter")
        try expect(try await app.store.work(id: group.id)?.isOnShelf == false, "Reading alone does not add the work to shelf")
        await app.updateScheduler.stop()
    },
    Check("SourceReadingTests.unavailableCardUsesFirstCompleteDownload") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root)
        let source = try await app.store.allSourceWorks()[0]; let group = try await app.store.workID(for: source.id)!
        let chapters = try await app.store.chapters(for: source.id)
        let pages = try await app.sources.pages(chapter: chapters[1])
        let id = try await app.downloads.enqueue(chapter: chapters[1], pages: pages)
        _ = try await waitForDownload(app.downloads, id)
        try await app.store.save(progress: ReadingProgress(chapterID: chapters[0].id, pageID: PageID(chapterID: chapters[0].id, externalID: "0")))
        try await app.store.remove(sourceID: source.id.sourceID)
        await app.openSource(source.id, for: group)
        try expect(await app.path == [.reader(chapters[1].id)], "An unavailable resume chapter falls back only to complete local content from the tapped source")
        await app.updateScheduler.stop()
    },
    Check("SourceReadingTests.unavailableCardWithoutDownloadsKeepsDetail") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root)
        let sources = try await app.store.allSourceWorks(); let group = try await app.store.workID(for: sources[0].id)!
        try await app.store.link(sources[1].id, to: group); try await app.store.remove(sourceID: sources[0].id.sourceID)
        await app.openSource(sources[0].id, for: group)
        try expect(await app.path.isEmpty, "Unavailable card never silently switches to another associated source")
        try expect(await app.message != nil, "No readable chapter presents a recoverable error")
        await app.updateScheduler.stop()
    },
    Check("SourceReadingTests.unavailableCardResumesOnlyVerifiedOfflineProgress") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root)
        let source = try await app.store.allSourceWorks()[0]; let group = try await app.store.workID(for: source.id)!
        let chapter = try await app.store.chapters(for: source.id)[1]
        let pages = try await app.sources.pages(chapter: chapter)
        let id = try await app.downloads.enqueue(chapter: chapter, pages: pages)
        _ = try await waitForDownload(app.downloads, id)
        try await app.store.save(progress: ReadingProgress(chapterID: chapter.id, pageID: pages[2].id, fraction: 0.5))
        try await app.store.remove(sourceID: source.id.sourceID)
        await app.openSource(source.id, for: group)
        try expect(await app.path == [.reader(chapter.id)], "A removed source can resume its complete downloaded chapter")
        let files = try await app.downloads.offlinePages(chapterID: chapter.id)
        try FileManager.default.removeItem(at: files[0])
        await MainActor.run { app.path = [] }
        await app.openSource(source.id, for: group)
        try expect(await app.path.isEmpty, "A damaged offline chapter cannot be advertised as readable")
        await app.updateScheduler.stop()
    },
    Check("SourceReadingTests.unassociatedCardCannotChangePreferenceOrRead") {
        let root = try Samples.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = try await UITestBootstrap.make(root: root)
        let sources = try await app.store.allSourceWorks(); let group = try await app.store.workID(for: sources[0].id)!
        await app.openSource(sources[1].id, for: group)
        try expect(await app.path.isEmpty, "A stale unlinked source card cannot enter the reader")
        try expect(try await app.store.work(id: group)?.preferredSourceWorkID == sources[0].id, "Unlinked source cannot replace the selected source")
        await app.updateScheduler.stop()
    }
]
