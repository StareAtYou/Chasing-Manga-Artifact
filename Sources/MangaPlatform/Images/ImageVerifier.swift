import Foundation
import ImageIO
import MangaCore
public struct ImageVerifier: ImageVerifying {
    public init() { }
    public func verify(_ data: Data) throws -> ImageMetadata {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256, kCGImageSourceShouldCache: false] as CFDictionary), image.width > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let type = CGImageSourceGetType(source) else { throw MangaError.invalidImage }
        return ImageMetadata(width: width, height: height, format: type as String)
    }
    public static var supportedFormats: [String] { CGImageSourceCopyTypeIdentifiers() as? [String] ?? [] }
}
