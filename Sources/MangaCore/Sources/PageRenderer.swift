import Foundation
public struct RenderedPage: Sendable {
    public let url: URL
    public let html: String
    public let accessContextID: UUID?
    public let metadata: [String: String]
    public init(url: URL, html: String, accessContextID: UUID? = nil, metadata: [String: String] = [:]) { self.url = url; self.html = html; self.accessContextID = accessContextID; self.metadata = metadata }
}
public protocol PageRenderer: Sendable {
    func render(url: URL, source: Source, interactive: Bool) async throws -> RenderedPage
}
