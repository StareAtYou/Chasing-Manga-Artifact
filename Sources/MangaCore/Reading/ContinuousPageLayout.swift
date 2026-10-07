import Foundation
public struct ReadingPageFrame: Sendable {
    public let minY: Double
    public let height: Double
    public var maxY: Double { minY + height }
    public init(minY: Double, height: Double) { self.minY = minY; self.height = height }
}
public enum ContinuousPageLayout {
    /// The page nearest the middle of the viewport owns the chapter title and progress.
    public static func visiblePage(_ pages: [PageID], frames: [PageID: ReadingPageFrame], viewportHeight: Double, intent: Int = 0) -> PageID? {
        if intent > 0, let last = pages.last, let frame = frames[last], frame.maxY > 1, frame.maxY <= viewportHeight + 1 { return last }
        if intent < 0, let first = pages.first, let frame = frames[first], frame.minY >= -1, frame.minY < viewportHeight { return first }
        let line = viewportHeight / 2
        let visible = pages.filter { if let frame = frames[$0] { return frame.maxY > 1 && frame.minY < viewportHeight }; return false }
        return visible.min { left, right in
            guard let a = frames[left], let b = frames[right] else { return false }
            func distance(_ frame: ReadingPageFrame) -> Double { max(0, max(frame.minY - line, line - frame.maxY)) }
            return distance(a) < distance(b)
        }
    }
}
