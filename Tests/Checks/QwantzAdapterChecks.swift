import Foundation
import MangaCore

private let qwantz = Source(name: "Dinosaur Comics", baseURL: URL(string: "https://www.qwantz.com/")!)
private let qwantzArchiveURL = URL(string: "https://www.qwantz.com/archive.php")!
private func qwantzComicURL(_ number: String) -> URL { URL(string: "https://www.qwantz.com/index.php?comic=\(number)")! }
private func qwantzWork() -> SourceWork {
    SourceWork(id: SourceWorkID(sourceID: qwantz.id, externalID: "qwantz"), title: "Dinosaur Comics", url: qwantz.baseURL)
}
private func qwantzChapter(_ number: String = "12") -> Chapter {
    Chapter(id: ChapterID(sourceWorkID: qwantzWork().id, externalID: number), title: "第\(number)期", url: qwantzComicURL(number), ordinal: 0)
}
// The public archive is newest first; IDs need not be consecutive or monotonic.
private let qwantzArchive = """
<a href='index.php?comic=999'>Random header comic</a>
<ul class='archive'>
<li><a href='http://www.qwantz.com/index.php?comic=12'>October 2nd, 2026</a>: Latest</li>
<li><a href='index.php?tracking=x&amp;comic=10#fragment'>October 1st, 2026</a>: Second</li>
<li><a href='index.php?comic=11'>September 30th, 2026</a>: First</li>
<li><a href='index.php?comic=11'>Duplicate link</a></li>
<li><a href='https://other.test/index.php?comic=9'>Offsite</a></li>
<li><a href='https://www.qwantz.com:444/index.php?comic=8'>Other port</a></li>
<li><a href='futurecomic.php?comic=7'>Paid preview</a></li>
<li><a href='index.php?comic=0'>Invalid</a></li>
<li><a href='index.php?comic=6&amp;comic=5'>Ambiguous</a></li>
</ul>
"""
private func qwantzHTML(_ number: String = "12", image: String = "comic2-99.png") -> String {
    """
    <title>Dinosaur Comics - October 2nd, 2026 - awesome fun times!</title>
    <meta property='og:url' content='https://www.qwantz.com/index.php?comic=\(number)'>
    <meta property='og:image' content='https://www.qwantz.com/comics/\(image)'>
    <meta property='og:description' content='Dinosaurs discuss life'>
    <img src='/logo5.png'><img src='/comics/banner.png'>
    <a href='futurecomic.php'><img class='comic' src='/comics/preview.png'></a>
    <center><img class='comic' src='comics/\(image)' title='Dinosaurs discuss life'></center>
    <img src='https://ads.test/ad.png'><img src='/patreon.png'>
    """
}
private func qwantzContext(_ entries: [String: ResourceResponse]) -> ParserContext {
    ParserContext(source: qwantz, client: FixtureHTTPClient(entries))
}
public let qwantzAdapterChecks: [Check] = [
    Check("QwantzAdapterTests.archiveUsesActualLinksAndChronology") {
        let chapters = try await QwantzAdapter().chapters(work: qwantzWork(), context: qwantzContext([qwantzArchiveURL.absoluteString: textResponse(qwantzArchive, qwantzArchiveURL)]))
        try expect(chapters.map(\.id.externalID) == ["11", "10", "12"] && chapters.map(\.ordinal) == [0, 1, 2], "Reverse real archive order, deduplicate IDs, and never invent gaps or sort IDs")
        try expect(chapters.map(\.url.absoluteString) == ["https://www.qwantz.com/index.php?comic=11", "https://www.qwantz.com/index.php?comic=10", "https://www.qwantz.com/index.php?comic=12"], "Canonical chapter URLs strip tracking while preserving exact source origin")
    },
    Check("QwantzAdapterTests.singleSeriesAndAuthorSearch") {
        let adapter = QwantzAdapter()
        let context = qwantzContext([qwantz.baseURL.absoluteString: textResponse(qwantzHTML(), qwantz.baseURL)])
        let work = try await adapter.browse(context: context)
        try expect(work.count == 1 && work[0].id.externalID == "qwantz" && work[0].author == "Ryan North" && work[0].coverURL?.absoluteString == "https://www.qwantz.com/comics/comic2-99.png" && work[0].latestChapter.contains("12"), "Identify the creator's single English series and actual latest comic")
        for query in ["Dinosaur Comics", "恐龙漫画", "qwantz", "Ryan North"] {
            try expect(try await adapter.search(query: query, context: context).count == 1, "Search recognizes series and creator aliases")
        }
        try expect(try await adapter.search(query: "unrelated series", context: qwantzContext([:])).isEmpty, "Do not pretend to search comic titles or fetch for unrelated series")
        try expect(try await adapter.search(query: " ", context: qwantzContext([:])).isEmpty, "Empty search returns no results")
    },
    Check("QwantzAdapterTests.bodyImageAndStableIdentity") {
        let chapter = qwantzChapter()
        let url = chapter.url
        let first = try await QwantzAdapter().pages(chapter: chapter, context: qwantzContext([url.absoluteString: textResponse(qwantzHTML(), url)]))
        let refreshed = try await QwantzAdapter().pages(chapter: chapter, context: qwantzContext([url.absoluteString: textResponse(qwantzHTML(image: "comic2-100.png"), url)]))
        try expect(first.count == 1 && first[0].request.url.absoluteString == "https://www.qwantz.com/comics/comic2-99.png" && first[0].request.referer == url, "Read the body image matching metadata, excluding navigation, ads and paid previews")
        try expect(first.map(\.id) == refreshed.map(\.id) && first[0].id.externalID == "1" && first[0].ordinal == 0, "Image URL changes preserve progress via an ordinal page identity")
    },
    Check("QwantzAdapterTests.rejectsMissingComicFallbackAndBadBody") {
        let chapter = qwantzChapter()
        let variants = [qwantzHTML("13"), qwantzHTML().replacingOccurrences(of: "src='comics/comic2-99.png'", with: "src='/comics/different.png'"), qwantzHTML().replacingOccurrences(of: "https://www.qwantz.com/comics/comic2-99.png", with: "https://other.test/comics/comic2-99.png")]
        for html in variants {
            do {
                _ = try await QwantzAdapter().pages(chapter: chapter, context: qwantzContext([chapter.url.absoluteString: textResponse(html, chapter.url)]))
                throw CheckFailure(description: "Accepted missing comic fallback or unverified/offsite body")
            } catch MangaError.parseMismatch { }
        }
    },
    Check("QwantzAdapterTests.blocksChallengeAndCrossOriginRedirect") {
        let url = qwantzChapter().url
        do {
            _ = try await QwantzAdapter().pages(chapter: qwantzChapter(), context: qwantzContext([url.absoluteString: textResponse("<title>Just a moment</title>" + qwantzHTML(), url)]))
            throw CheckFailure(description: "Challenge accepted")
        } catch MangaError.verificationRequired { }
        do {
            _ = try await QwantzAdapter().pages(chapter: qwantzChapter(), context: qwantzContext([url.absoluteString: textResponse(qwantzHTML(), URL(string: "https://other.test/")!)]))
            throw CheckFailure(description: "Cross-origin redirect accepted")
        } catch MangaError.unsupported { }
    },
    Check("QwantzAdapterTests.rejectsMismatchedChapterAndNestedSource") {
        let chapter = qwantzChapter()
        let wrongURL = Chapter(id: chapter.id, title: chapter.title, url: qwantzComicURL("13"), ordinal: 0)
        do {
            _ = try await QwantzAdapter().pages(chapter: wrongURL, context: qwantzContext([:]))
            throw CheckFailure(description: "Requested URL mismatches saved chapter identity")
        } catch MangaError.invalidURL { }
        let nested = Source(name: "Wrong path", baseURL: URL(string: "https://www.qwantz.com/mirror/")!)
        do {
            _ = try await QwantzAdapter().browse(context: ParserContext(source: nested, client: FixtureHTTPClient([:])))
            throw CheckFailure(description: "Configured subpath escaped")
        } catch MangaError.invalidURL { }
    },
    Check("QwantzAdapterTests.rejectsEmptyArchive") {
        do {
            _ = try await QwantzAdapter().chapters(work: qwantzWork(), context: qwantzContext([qwantzArchiveURL.absoluteString: textResponse("<a href='index.php?comic=12'>Navigation only</a>", qwantzArchiveURL)]))
            throw CheckFailure(description: "Empty archive accepted")
        } catch MangaError.parseMismatch { }
    }
]
