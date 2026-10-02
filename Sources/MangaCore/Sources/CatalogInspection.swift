import Foundation
public struct CatalogInspection: Sendable {
    public let sourceID: SourceID
    public let works: [SourceWork]
    public let errors: [String: MangaError]
    public init(sourceID: SourceID, works: [SourceWork], errors: [String: MangaError]) { self.sourceID = sourceID; self.works = works; self.errors = errors }
}
