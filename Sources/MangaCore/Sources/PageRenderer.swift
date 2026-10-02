import Foundation
public struct RenderedPage: Sendable {
    public let url: URL
    public let html: String
    public let accessContextID: UUID?
    public init(url: URL, html: String, accessContextID: UUID? = nil) { self.url = url; self.html = html; self.accessContextID = accessContextID }
}
public protocol PageRenderer: Sendable {
    func render(url: URL, source: Source, interactive: Bool) async throws -> RenderedPage
}
