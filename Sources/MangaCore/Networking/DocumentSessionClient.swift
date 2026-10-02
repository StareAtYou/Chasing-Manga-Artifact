import Foundation
// A short-lived document session: only one opening/probe owns this cache.
// It never retains chapter signatures across separate user operations.
actor DocumentSessionClient: HTTPClient {
    private let client: any HTTPClient
    private var responses: [ResourceRequest: ResourceResponse] = [:]
    init(_ client: any HTTPClient) { self.client = client }
    func send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse {
        try Task.checkCancellation()
        if let response = responses[request] { return response }
        let response = try await client.send(request, sourceID: sourceID, priority: priority)
        try Task.checkCancellation(); responses[request] = response; return response
    }
}
