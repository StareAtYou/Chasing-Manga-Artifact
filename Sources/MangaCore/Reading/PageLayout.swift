import Foundation
public enum PageLayout {
    public static func spreads(pageIDs: [PageID], direction: ReadingDirection) -> [[PageID]] {
        guard let first = pageIDs.first else { return [] }
        var result = [[first]]; var index = 1
        while index < pageIDs.count {
            let end = min(index + 2, pageIDs.count); let pair = Array(pageIDs[index..<end])
            result.append(direction == .rightToLeft ? pair.reversed() : pair); index = end
        }
        return result
    }
    public static func destination(from pageID: PageID, pageIDs: [PageID], mode: ReadingMode, direction: ReadingDirection, visualDelta: Int) -> PageID? {
        let delta = direction == .rightToLeft ? -visualDelta : visualDelta
        let groups = mode == .doublePage ? spreads(pageIDs: pageIDs, direction: direction) : pageIDs.map { [$0] }
        guard let index = groups.firstIndex(where: { $0.contains(pageID) }), groups.indices.contains(index + delta) else { return nil }
        return pageIDs.first { groups[index + delta].contains($0) }
    }
}
