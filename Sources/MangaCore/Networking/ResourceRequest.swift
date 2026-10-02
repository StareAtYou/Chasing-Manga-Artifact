import Foundation
public enum HTTPMethod: String, Codable, Sendable { case get = "GET", post = "POST" }
public struct ResourceRequest: Codable, Hashable, Sendable {
    public var url: URL
    public var referer: URL?
    public var headers: [String: String]
    public var accessContextID: UUID?
    public var method: HTTPMethod?
    public var body: Data?
    public init(url: URL, referer: URL? = nil, headers: [String: String] = [:], accessContextID: UUID? = nil, method: HTTPMethod? = nil, body: Data? = nil) {
        self.url = url; self.referer = referer; self.headers = headers; self.accessContextID = accessContextID; self.method = method; self.body = body
    }
}
public struct ResourceResponse: Sendable {
    public let data: Data
    public let finalURL: URL
    public let statusCode: Int
    public let headers: [String: String]
    public init(data: Data, finalURL: URL, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data; self.finalURL = finalURL; self.statusCode = statusCode; self.headers = headers
    }
    public var text: String { String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? "" }
}
