import Foundation

/// Exact row geometry shared by the native scroll containers. Heights include row spacing.
public struct ReadingScrollRow: Hashable, Sendable {
    public let id: String
    public let height: Double
    public let anchors: Bool
    public init(id: String, height: Double, anchors: Bool = true) {
        self.id = id; self.height = height.isFinite ? max(0, height) : 0; self.anchors = anchors
    }
}
public struct ReadingScrollLayout: Equatable, Sendable {
    public let rows: [ReadingScrollRow]
    public let frames: [String: ReadingPageFrame]
    public let height: Double
    public init(rows: [ReadingScrollRow]) {
        self.rows = rows
        var result: [String: ReadingPageFrame] = [:]; var y = 0.0
        for row in rows { result[row.id] = ReadingPageFrame(minY: y, height: row.height); y += row.height }
        frames = result; height = y
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.rows == rhs.rows }
    public func materializedRows(from old: Self, offset: Double, viewportHeight: Double, margin: Double) -> Set<String> {
        let projected = preservingOffset(from: old, offset: offset)
        return Set(rows.filter { row in
            guard let frame = frames[row.id] else { return false }
            return frame.maxY > projected - margin && frame.minY < projected + viewportHeight + margin
        }.map(\.id))
    }
    public func preservingOffset(from old: Self, offset: Double) -> Double {
        guard offset.isFinite else { return 0 }
        let retained = old.rows.filter { $0.anchors && frames[$0.id] != nil }
        guard let anchor = retained.first(where: { (old.frames[$0.id]?.maxY ?? 0) > offset }) ?? retained.last,
              let before = old.frames[anchor.id], let after = frames[anchor.id] else { return offset }
        let within = offset - before.minY
        // Preserve a point inside a resized image proportionally; an anchor below the
        // viewport keeps its exact screen Y (including headers and row spacing).
        let relative = within >= 0 && within < before.height && before.height > 0 ? within * after.height / before.height : within
        return after.minY + relative
    }
}
