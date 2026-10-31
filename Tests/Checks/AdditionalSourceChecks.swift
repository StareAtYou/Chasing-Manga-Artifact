import Foundation
import MangaCore
private let dex = Source(name: "MangaDex", baseURL: URL(string: "https://mangadex.org/")!)
private let xkcd = Source(name: "xkcd", baseURL: URL(string: "https://xkcd.com/")!)
private let mangaUUID = "67f7d17a-d448-411d-ab6a-5649b3ebe7f0"
private let chapterUUID = "34f61dca-9a42-4ce3-9495-38e6574a1cc6"
private func adapter(_ source: Source) throws -> any SourceAdapter { guard let value = BuiltinSources.candidateAdapter(for: source) else { throw CheckFailure(description: "Missing adapter for \(source.name)") };return value }
private let mangaJSON = #"{"result":"ok","data":{"id":"67f7d17a-d448-411d-ab6a-5649b3ebe7f0","type":"manga","attributes":{"title":{"en":"Fei Ren Zai"},"altTitles":[{"zh":"非人哉"}],"description":{"en":"A comic about mythical creatures"}},"relationships":[{"id":"cover","type":"cover_art","attributes":{"fileName":"cover.jpg","description":"","volume":null}},{"id":"author","type":"author","attributes":{"name":"一汪空气"}}]}}"#
private let feedJSON = #"{"result":"ok","total":3,"data":[{"id":"34f61dca-9a42-4ce3-9495-38e6574a1cc6","attributes":{"chapter":"1","title":"A Long Time Ago","translatedLanguage":"en","pages":5,"externalUrl":null,"isUnavailable":false},"relationships":[{"id":"group","type":"scanlation_group","attributes":{"name":"Mochi Scans"}}]},{"id":"external","attributes":{"chapter":"2","title":"External","translatedLanguage":"en","pages":0,"externalUrl":"https://other.test/","isUnavailable":false},"relationships":[]},{"id":"removed","attributes":{"chapter":"3","translatedLanguage":"en","pages":0,"isUnavailable":true},"relationships":[]}]}"#
private let homeJSON = #"{"result":"ok","baseUrl":"https://cdn.mangadex.network","chapter":{"hash":"abc","data":["large1.jpg","large2.jpg"],"dataSaver":["small1.jpg","small2.jpg"]}}"#
private let xkcdJSON = #"{"num":405,"safe_title":"Journal","title":"Journal","img":"https://imgs.xkcd.com/comics/journal.png","alt":"Original alt text","year":"2008","month":"4","day":"7"}"#
public let additionalSourceChecks: [Check] = [
    Check("AdditionalSourceTests.expansionPreservesExistingSourceIdentities") {
        let sources=BuiltinSources.candidates()
        try expect(sources.count == 14 && Set(sources.map(\.id)).count == sources.count,"All added sources have distinct stable IDs")
        for index in 0..<6 {
            try expect(sources[index].id.rawValue == UUID(uuidString:"00000000-0000-0000-0000-00000000010\(index)"),"Source expansion preserves persisted original identities")
        }
    },
    Check("AdditionalSourceTests.mangaDexDetailsAndCredits") {
        let a = try adapter(dex); let url = dex.baseURL.appendingPathComponent("title/"+mangaUUID)
        let endpoint = URL(string:"https://api.mangadex.org/manga/\(mangaUUID)?includes%5B%5D=cover_art&includes%5B%5D=author&includes%5B%5D=artist")!
        let ctx = ParserContext(source:dex,client:FixtureHTTPClient([endpoint.absoluteString:textResponse(mangaJSON,endpoint)]))
        let work = try await a.details(url:url,context:ctx)
        try expect(work.id.externalID == mangaUUID && work.title == "非人哉" && work.author == "一汪空气" && work.coverURL?.host == "uploads.mangadex.org", "Prefer Chinese title, retain credit and public cover")
    },
    Check("AdditionalSourceTests.mangaDexFeedSkipsExternalAndUnavailable") {
        let a = try adapter(dex);let work = SourceWork(id:SourceWorkID(sourceID:dex.id,externalID:mangaUUID),title:"非人哉",url:dex.baseURL.appendingPathComponent("title/"+mangaUUID))
        let endpoint = URL(string:"https://api.mangadex.org/manga/\(mangaUUID)/feed?limit=100&offset=0&translatedLanguage%5B%5D=zh&translatedLanguage%5B%5D=zh-hk&translatedLanguage%5B%5D=en&order%5Bchapter%5D=asc&includes%5B%5D=scanlation_group")!
        let chapters = try await a.chapters(work:work,context:ParserContext(source:dex,client:FixtureHTTPClient([endpoint.absoluteString:textResponse(feedJSON,endpoint)])))
        try expect(chapters.count == 1 && chapters[0].id.externalID == chapterUUID && chapters[0].title.contains("Mochi Scans") && chapters[0].title.contains("en"),"Do not treat offsite/unavailable chapters as readable; credit group and language")
    },
    Check("AdditionalSourceTests.mangaDexDataSaverAndStablePageIdentity") {
        let a = try adapter(dex);let work = SourceWork(id:SourceWorkID(sourceID:dex.id,externalID:mangaUUID),title:"非人哉",url:dex.baseURL.appendingPathComponent("title/"+mangaUUID));let ch = Chapter(id:ChapterID(sourceWorkID:work.id,externalID:chapterUUID),title:"1",url:dex.baseURL.appendingPathComponent("chapter/"+chapterUUID),ordinal:0)
        let endpoint = URL(string:"https://api.mangadex.org/at-home/server/\(chapterUUID)?forcePort443=true")!
        let first = try await a.pages(chapter:ch,context:ParserContext(source:dex,client:FixtureHTTPClient([endpoint.absoluteString:textResponse(homeJSON,endpoint)])))
        let refreshed = homeJSON.replacingOccurrences(of:"cdn.mangadex.network",with:"new.mangadex.network").replacingOccurrences(of:"abc",with:"newhash")
        let second = try await a.pages(chapter:ch,context:ParserContext(source:dex,client:FixtureHTTPClient([endpoint.absoluteString:textResponse(refreshed,endpoint)])))
        try expect(first.count == 2 && first[0].request.url.path == "/data-saver/abc/small1.jpg" && first.map(\.id) == second.map(\.id),"Use smaller image variant while refreshed CDN addresses retain progress")
    },
    Check("AdditionalSourceTests.mangaDexRejectsInvalidCDN") {
        let a = try adapter(dex);let ch = Chapter(id:ChapterID(sourceWorkID:SourceWorkID(sourceID:dex.id,externalID:mangaUUID),externalID:chapterUUID),title:"1",url:dex.baseURL.appendingPathComponent("chapter/"+chapterUUID),ordinal:0)
        let endpoint = URL(string:"https://api.mangadex.org/at-home/server/\(chapterUUID)?forcePort443=true")!
        let value = homeJSON.replacingOccurrences(of:"https://cdn.mangadex.network",with:"https://user:password@other.test")
        do { _ = try await a.pages(chapter:ch,context:ParserContext(source:dex,client:FixtureHTTPClient([endpoint.absoluteString:textResponse(value,endpoint)])));throw CheckFailure(description:"Invalid CDN accepted") } catch MangaError.parseMismatch { }
    },
    Check("AdditionalSourceTests.xkcdCompleteArchiveAndPublicImage") {
        let a = try adapter(xkcd);let latest = URL(string:"https://xkcd.com/info.0.json")!;let item = URL(string:"https://xkcd.com/405/info.0.json")!
        let ctx = ParserContext(source:xkcd,client:FixtureHTTPClient([latest.absoluteString:textResponse(xkcdJSON,latest),item.absoluteString:textResponse(xkcdJSON,item)]))
        let work = try await a.details(url:xkcd.baseURL,context:ctx);let chapters = try await a.chapters(work:work,context:ctx)
        try expect(chapters.count == 404 && !chapters.contains{$0.id.externalID == "404"} && chapters.last?.id.externalID == "405", "Complete numbered archive omits deliberately absent issue 404")
        let pages = try await a.pages(chapter:chapters.last!,context:ctx)
        try expect(pages.count == 1 && pages[0].request.url.absoluteString == "https://imgs.xkcd.com/comics/journal.png", "Use actual JSON image rather than homepage assets")
        try expect(try await a.search(query:"xkcd",context:ctx).count == 1,"Search identifies the series")
    }
]
