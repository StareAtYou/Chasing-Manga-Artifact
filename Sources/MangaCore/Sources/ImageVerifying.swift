import Foundation
public struct ImageMetadata: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let format: String
    public init(width: Int, height: Int, format: String) { self.width = width; self.height = height; self.format = format }
}
public protocol ImageVerifying: Sendable { func verify(_ data: Data) throws -> ImageMetadata }
