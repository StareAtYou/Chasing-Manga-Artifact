import Foundation
import MangaCore
public let identityChecks: [Check] = [
    Check("IdentityTests.sameExternalIDOnDifferentSources") {
        let a = SourceWorkID(sourceID: SourceID(), externalID: "42")
        let b = SourceWorkID(sourceID: SourceID(), externalID: "42")
        try expect(ChapterID(sourceWorkID: a, externalID: "1") != ChapterID(sourceWorkID: b, externalID: "1"), "Different sources must not share chapter identity")
    },
    Check("IdentityTests.differentBasePathsStayDistinct") {
        try expect(canonicalSourceURL(URL(string: "https://EXAMPLE.com:443/a/#top")!).absoluteString == "https://example.com/a/", "Normalize host and default port")
        try expect(canonicalSourceURL(URL(string: "https://example.com/b/")!).absoluteString == "https://example.com/b/", "Preserve source subpaths")
    },
    Check("IdentityTests.ephemeralURLDoesNotChangePageIdentity") {
        let chapter = ChapterID(sourceWorkID: SourceWorkID(sourceID: SourceID(), externalID: "42"), externalID: "3")
        let id = PageID(chapterID: chapter, externalID: "1")
        let a = PageResource(id: id, ordinal: 0, request: ResourceRequest(url: URL(string: "https://img.test/1?sign=old")!))
        let b = PageResource(id: id, ordinal: 0, request: ResourceRequest(url: URL(string: "https://img.test/1?sign=new")!))
        try expect(a.id == b.id && a.request.url != b.request.url, "URL signature is not a page ID")
    },
    Check("IdentityTests.rejectsNonWebSourceAndPreservesSemanticQuery") {
        try expectError { _ = try canonicalSourceURL(URL(string: "file:///tmp/source")!) }
        try expect(canonicalSourceURL(URL(string: "https://example.com/comic.php?id=42#reader")!).absoluteString == "https://example.com/comic.php?id=42", "Keep chapter query parameters")
    }
]
