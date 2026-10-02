import Foundation
public struct AssociationCandidate: Sendable, Identifiable {
    public var id: SourceWorkID { work.id }
    public let work: SourceWork
    public let reason: String
}
public enum MangaTitle {
    public static func normalized(_ title: String) -> String {
        title.precomposedStringWithCanonicalMapping.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "zh_CN")).filter { !$0.isWhitespace }
    }
    static func edition(_ title: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"第[0-9一二三四五六七八九十]+季|season\s*\d+|彩色版|黑白版|完全版|重制版|修订版|原版|新装版|单行本|短篇版|长篇版"#, options: .caseInsensitive)
        return expression.matches(in: title, range: NSRange(title.startIndex..., in: title)).compactMap { Range($0.range, in: title).map { normalized(String(title[$0])) } }
    }
}
public struct AssociationService: Sendable {
    private let store: LibraryStore
    public init(store: LibraryStore) { self.store = store }
    public func candidates(for work: SourceWork, among others: [SourceWork]) -> [AssociationCandidate] {
        let titles = Set(([work.title] + work.aliases).map(MangaTitle.normalized))
        return others.compactMap { other in
            guard other.id != work.id, other.id.sourceID != work.id.sourceID, MangaTitle.edition(work.title) == MangaTitle.edition(other.title), !titles.isDisjoint(with: ([other.title] + other.aliases).map(MangaTitle.normalized)) else { return nil }
            let sameAuthor = !work.author.isEmpty && !other.author.isEmpty && MangaTitle.normalized(work.author) == MangaTitle.normalized(other.author)
            return AssociationCandidate(work: other, reason: sameAuthor ? "名称与作者相符，请确认是否关联" : "名称相符，请核对作者与版本后确认")
        }
    }
    public func confirmLink(_ sourceWorkID: SourceWorkID, to workID: WorkID) async throws { try await store.link(sourceWorkID, to: workID) }
    public func unlink(_ sourceWorkID: SourceWorkID, from workID: WorkID) async throws { try await store.unlink(sourceWorkID, from: workID) }
}
