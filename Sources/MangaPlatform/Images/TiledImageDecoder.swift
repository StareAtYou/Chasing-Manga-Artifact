import Foundation
import CoreGraphics
import ImageIO
import MangaCore
public struct PixelRect: Sendable, Hashable {
    public let x: Int; public let y: Int; public let width: Int; public let height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
}
public struct ImageTile: @unchecked Sendable {
    public let frame: PixelRect
    public let image: CGImage
    public let scaleFactor: Double
    public var decodedBytes: Int { image.bytesPerRow * image.height }
    public var isSubsampled: Bool { scaleFactor < 1 }
}
public struct TiledImageDecoder: Sendable {
    public init() { }
    public func decode(file: URL, viewport: PixelRect, targetWidth: Int) throws -> [ImageTile] {
        guard targetWidth > 0, viewport.width > 0, viewport.height > 0,
              let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { throw MangaError.invalidImage }
        // Bound decoded pixel count, not the longest edge: a narrow webtoon can be
        // very tall and still fit comfortably. Never fully decode an oversized original.
        let pixels = Double(width) * Double(height)
        let factor = min(1, Double(targetWidth) / Double(width), sqrt(Double(8 * 1024 * 1024) / pixels))
        let dimension = max(1, Int(min(65_536, ceil(Double(max(width, height)) * factor))))
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: dimension, kCGImageSourceShouldCacheImmediately: true, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw MangaError.invalidImage }
        let scale = min(Double(thumbnail.width) / Double(width), Double(thumbnail.height) / Double(height))
        let start = max(0, min(height, viewport.y)); let end = min(height, max(start, viewport.y + min(viewport.height, height)))
        var result: [ImageTile] = []
        for y in stride(from: (start / 4096) * 4096, to: end, by: 4096) {
            let tileHeight = min(4096, height - y)
            let top = max(0, Int(floor(Double(y) * scale))); let bottom = min(thumbnail.height, Int(ceil(Double(y + tileHeight) * scale)))
            guard bottom > top, let image = thumbnail.cropping(to: CGRect(x: 0, y: top, width: thumbnail.width, height: bottom - top)) else { continue }
            result.append(ImageTile(frame: PixelRect(x: 0, y: y, width: width, height: tileHeight), image: image, scaleFactor: scale))
        }
        return result
    }
}
