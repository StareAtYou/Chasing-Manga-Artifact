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
}
