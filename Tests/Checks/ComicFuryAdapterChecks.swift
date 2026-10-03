import Foundation
import MangaCore

private let furySource = Source(name: "ComicFury", baseURL: URL(string: "https://comicfury.com/")!)
private let furyProfileURL = URL(string: "https://comicfury.com/comicprofile.php?url=demo")!
private let furyArchiveURL = URL(string: "https://comicfury.com/read/demo/archive")!
private let furyChapterURL = URL(string: "https://comicfury.com/read/demo/comics/90")!
private let furyWork = SourceWork(id: SourceWorkID(sourceID: furySource.id, externalID: "demo"), title: "Demo", url: furyProfileURL)
private let furyChapter = Chapter(id: ChapterID(sourceWorkID: furyWork.id, externalID: "90"), title: "First", url: furyChapterURL, ordinal: 0)
private let furyProfile = """
<img src='/avatars/commenter.png'>
<div class='profileinfobox'><div class='username-and-title'><div class='authorname'>Demo &amp; Friends<br></div><em>Tagline</em></div>
<div class='profile-avatar'><img src='/comicavatars/cover.webp'></div>
<div class='user-metadata'><a href='/read/demo/archive'>Go to Archive</a></div></div>
<div class='profilecategory'><h2 class='pchead'>Webcomic description</h2><div class='pccontent'>A library story.<div class='description-tags'><a>Comedy</a></div></div></div>
<div class='profilecategory'><h2 class='pchead'>Authors</h2><div class='pccontent'><a class='authorname'>Writer</a><a class='authorname'>Artist</a></div></div>
<div class='form-box-content'>Unrelated comment</div>
"""
private func furyArchive(_ entries: [(String, String)], page: Int = 1, last: Int = 1) -> String {
    let links = last > 1 ? (1...last).map { $0 == page ? "<span class='vfpage vfpagecurrent'>\($0)</span>" : "<a class='vfpage' href='/read/demo/archive/page/\($0)'>\($0)</a>" }.joined() : ""
    return "<div class='archive-pages'>\(links)</div><div class='archive-comics'>" + entries.map { "<a href='\($0.0)'><span class='archive-comic-title'>\($0.1)</span></a>" }.joined() + "</div>"
}
private func furyReader(_ imageURLs: [String], comicID: String = "90") -> String {
    "<div class='is--comic-page' data-comicid='\(comicID)'><div class='is--comic-content'>" + imageURLs.map { "<div class='is--image-segment'><img src='\($0)'></div>" }.joined() + "</div></div>"
}
private func furyContext(_ responses: [URL: String]) -> ParserContext {
    ParserContext(source: furySource, client: FixtureHTTPClient(Dictionary(uniqueKeysWithValues: responses.map { ($0.key.absoluteString, textResponse($0.value, $0.key)) })))
}
private func furyMustReject(_ body: () async throws -> Void) async throws {
    do { try await body() } catch is MangaError { return }
    throw CheckFailure(description: "ComicFury must reject malformed or incomplete data")
}

public let comicFuryAdapterChecks: [Check] = [
    Check("ComicFuryAdapterTests.searchAndBrowseKeepOnlyScopedProfileResults") {
        let html = """
        <a href='/comicprofile.php?url=unrelated'>Header</a>
        <div class='webcomic-results'><div class='webcomic-result'><div class='webcomic-result-avatar'><img src='/comicavatars/cover.webp'></div><div class='webcomic-result-title'><a href='/comicprofile.php?url=demo'>Demo &amp; Friends</a></div></div>
        <div class='webcomic-result'><div class='webcomic-result-title'><a href='https://comicfury.com.evil.test/comicprofile.php?url=trap'>Trap</a></div></div>
        <div class='webcomic-result'><div class='webcomic-result-title'><a href='/comicprofile.php?url=demo&amp;url=other'>Duplicate query</a></div></div>
        <div class='webcomic-result'><div class='webcomic-result-title'><a href='/comicprofile.php?url=demo'>Duplicate</a></div></div></div>
        """
        let searchURL = URL(string: "https://comicfury.com/search.php?vr=1&combinedquery=Demo%20%26%20Friends")!
        let browseURL = URL(string: "https://comicfury.com/search.php")!
        let adapter = ComicFuryAdapter()
        let ctx = furyContext([searchURL: html, browseURL: html])
        for works in [try await adapter.search(query: "Demo & Friends", context: ctx), try await adapter.browse(context: ctx)] {
            try expect(works.count == 1 && works[0].title == "Demo & Friends" && works[0].id.externalID == "demo", "Profile result identity and title must exclude header, foreign and duplicate links")
            try expect(works[0].coverURL?.absoluteString == "https://comicfury.com/comicavatars/cover.webp", "Resolve the result's cover")
        }
    },
    Check("ComicFuryAdapterTests.detailsUseProfileMetadataWithoutCommentOrTagPollution") {
        let work = try await ComicFuryAdapter().details(url: furyProfileURL, context: furyContext([furyProfileURL: furyProfile]))
        try expect(work.title == "Demo & Friends" && work.author == "Writer / Artist" && work.summary == "A library story.", "Use profile name, authors and description only")
        try expect(work.id.externalID == "demo" && work.coverURL?.path == "/comicavatars/cover.webp", "Profile identity and icon are stable")
    },
    Check("ComicFuryAdapterTests.archiveLoadsAllPagesInArchiveOrder") {
        let second = URL(string: "https://comicfury.com/read/demo/archive/page/2")!
        let third = URL(string: "https://comicfury.com/read/demo/archive/page/3")!
        let firstHTML = furyArchive([("/read/demo/comics/90", "First"), ("/read/demo/comics/10", "Second"), ("/read/other/comics/33", "Trap")], last: 3)
        let ctx = furyContext([furyArchiveURL: firstHTML, second: furyArchive([("/read/demo/comics/50", "Third")], page: 2, last: 3), third: furyArchive([("/read/demo/comics/40", "Fourth")], page: 3, last: 3)])
        let chapters = try await ComicFuryAdapter().chapters(work: furyWork, context: ctx)
        try expect(chapters.map(\.title) == ["First", "Second", "Third", "Fourth"] && chapters.map(\.ordinal) == [0, 1, 2, 3], "Use every archive page in actual document order, never numeric comic-ID sorting")
        try expect(chapters.map { $0.id.externalID } == ["90", "10", "50", "40"], "Only this work's numeric chapter links establish identity")
    },
    Check("ComicFuryAdapterTests.archiveRejectsIncompleteOrRepeatedPagination") {
        let second = URL(string: "https://comicfury.com/read/demo/archive/page/2")!
        let first = furyArchive([("/read/demo/comics/90", "First")], last: 2)
        for secondHTML in [furyArchive([("/read/demo/comics/90", "First")], page: 2, last: 2), furyArchive([], page: 2, last: 2), furyArchive([("/read/demo/comics/10", "Second")], page: 1, last: 2)] {
            try await furyMustReject { _ = try await ComicFuryAdapter().chapters(work: furyWork, context: furyContext([furyArchiveURL: first, second: secondHTML])) }
        }
        try await furyMustReject { _ = try await ComicFuryAdapter().chapters(work: furyWork, context: furyContext([furyArchiveURL: first])) }
        let excessive = furyArchive([("/read/demo/comics/90", "First")]) + "<a class='vfpage' href='/read/demo/archive/page/1001'>1001</a>"
        try await furyMustReject { _ = try await ComicFuryAdapter().chapters(work: furyWork, context: furyContext([furyArchiveURL: excessive])) }
    },
    Check("ComicFuryAdapterTests.readerUsesOnlyRequestedComicSegmentsAndStablePageIDs") {
        let first = "https://img.comicfury.com/comics/1/a.jpg?token=old"
        let second = "https://img.comicfury.com/comics/1/b.jpg"
        let html = "<img src='https://ads.test/ad.jpg'>" + furyReader([first, second]) + furyReader(["https://img.comicfury.com/comics/1/next.jpg"], comicID: "91")
        let adapter = ComicFuryAdapter()
        let pages = try await adapter.pages(chapter: furyChapter, context: furyContext([furyChapterURL: html]))
        let refreshed = try await adapter.pages(chapter: furyChapter, context: furyContext([furyChapterURL: furyReader([first.replacingOccurrences(of: "old", with: "new"), second])]))
        try expect(pages.map { $0.request.url.lastPathComponent } == ["a.jpg", "b.jpg"] && pages.map(\.ordinal) == [0, 1], "Only matching comic image segments become reader pages")
        try expect(pages.map(\.id) == refreshed.map(\.id) && pages.map { $0.id.externalID } == ["1", "2"], "Page identities survive refreshed image query tokens")
        try expect(pages.allSatisfy { $0.request.referer == furyChapterURL }, "Keep reader referer")
    },
    Check("ComicFuryAdapterTests.rejectsCrossWorkAndMalformedInputBeforeFetching") {
        let client = FixtureHTTPClient([:]); let ctx = ParserContext(source: furySource, client: client); let adapter = ComicFuryAdapter()
        for raw in ["https://comicfury.com/comicprofile.php?url=demo&url=other", "http://comicfury.com/comicprofile.php?url=demo", "https://comicfury.com/comicprofile.php?url=..%2Fother", "https://comicfury.com/comicprofile.php?url=demo&redirect=other"] {
            do { _ = try await adapter.details(url: URL(string: raw)!, context: ctx); throw CheckFailure(description: "Invalid profile accepted") } catch MangaError.invalidURL { }
        }
        for raw in ["https://comicfury.com/read/other/comics/90", "https://comicfury.com/read/demo/comics/91", "https://comicfury.com/read/demo/comics/90?redirect=other"] {
            let chapter = Chapter(id: furyChapter.id, title: "Bad", url: URL(string: raw)!, ordinal: 0)
            do { _ = try await adapter.pages(chapter: chapter, context: ctx); throw CheckFailure(description: "Mismatched chapter accepted") } catch MangaError.invalidURL { }
        }
        let wrongWork = SourceWork(id: furyWork.id, title: "Bad", url: URL(string: "https://comicfury.com/comicprofile.php?url=other")!)
        do { _ = try await adapter.chapters(work: wrongWork, context: ctx); throw CheckFailure(description: "Mismatched work accepted") } catch MangaError.invalidURL { }
        try expect(await client.requests.isEmpty, "Reject invalid identity before requesting any URL")
    },
    Check("ComicFuryAdapterTests.unsupportedMediaNoticeIsExplicitAndScopedToRequestedComic") {
        let notice = "<div class='is--comic-page' data-comicid='90'><div class='is--comic-content'><div class='is--image-segments'><div class='is--unsupported-notice'><img src='/images/icons/unknown-media-white.svg'>This comic is in a format that cannot be displayed inside this feed. <a href='https://demo.thecomicseries.com/comics/pl/90/'>View it on the Webcomic Site</a></div></div></div></div>"
        let client = FixtureHTTPClient([furyChapterURL.absoluteString: textResponse(notice, furyChapterURL)])
        do {
            _ = try await ComicFuryAdapter().pages(chapter: furyChapter, context: ParserContext(source: furySource, client: client))
            throw CheckFailure(description: "Unsupported media must not become an icon page")
        } catch MangaError.unsupported(let reason) {
            try expect(reason.contains("媒体格式") && reason.contains("原站"), "Give a clear unsupported-format explanation")
        }
        try expect(await client.requests.count == 1, "Never follow the notice's creator-site link automatically")
        let supported = furyReader(["https://img.comicfury.com/comics/1/a.jpg"]) + notice.replacingOccurrences(of: "data-comicid='90'", with: "data-comicid='91'")
        let pages = try await ComicFuryAdapter().pages(chapter: furyChapter, context: furyContext([furyChapterURL: supported]))
        try expect(pages.count == 1 && pages[0].request.url.lastPathComponent == "a.jpg", "An unsupported neighboring comic must not block the requested image comic")
    },
    Check("ComicFuryAdapterTests.readerImageCannotEscapeComicsDirectory") {
        for image in ["https://img.comicfury.com/comics/../avatars/avatar.jpg", "https://img.comicfury.com/comics/%2E%2E/avatars/avatar.jpg"] {
            try await furyMustReject { _ = try await ComicFuryAdapter().pages(chapter: furyChapter, context: furyContext([furyChapterURL: furyReader([image])])) }
        }
    },
    Check("ComicFuryAdapterTests.rejectsCaptchaRedirectsAndUntrustedImages") {
        let adapter = ComicFuryAdapter()
        for operation in 0...2 {
            let url = operation == 0 ? furyProfileURL : operation == 1 ? furyArchiveURL : furyChapterURL
            let ctx = furyContext([url: "<title>Just a moment...</title>"])
            do {
                if operation == 0 { _ = try await adapter.details(url: url, context: ctx) }
                else if operation == 1 { _ = try await adapter.chapters(work: furyWork, context: ctx) }
                else { _ = try await adapter.pages(chapter: furyChapter, context: ctx) }
                throw CheckFailure(description: "Challenge must remain visible")
            } catch MangaError.verificationRequired { }
        }
        let foreign = URL(string: "https://evil.test/read/demo/comics/90")!
        let response = textResponse(furyReader(["https://img.comicfury.com/comics/1/a.jpg"]), foreign)
        let redirectCtx = ParserContext(source: furySource, client: FixtureHTTPClient([furyChapterURL.absoluteString: response]))
        try await furyMustReject { _ = try await adapter.pages(chapter: furyChapter, context: redirectCtx) }
        for image in ["https://ads.test/banner.jpg", "https://img.comicfury.com/avatars/avatar.jpg", "https://img.comicfury.com:444/comics/1/a.jpg", "http://img.comicfury.com/comics/1/a.jpg"] {
            try await furyMustReject { _ = try await adapter.pages(chapter: furyChapter, context: furyContext([furyChapterURL: furyReader([image])])) }
        }
    }
]
