import Foundation
import MangaCore

actor SequenceTransport: HTTPTransport {
    var responses: [ResourceResponse]
    var active = 0
    var maximum = 0
    init(_ responses: [ResourceResponse]) { self.responses = responses }
    func load(_ request: URLRequest) async throws -> ResourceResponse {
        active += 1; maximum = max(maximum, active)
        for _ in 0..<30 { await Task.yield() }
        active -= 1
        if responses.isEmpty { return ResourceResponse(data: Data(), finalURL: request.url!, statusCode: 200) }
        return responses.removeFirst()
    }
}
actor ImmediateSleeper: RequestSleeper {
    var delays: [Double] = []
    func sleep(seconds: Double) async throws { try Task.checkCancellation(); delays.append(seconds) }
}
actor BlockingTransport: HTTPTransport {
    var paths: [String] = []
    var gates: [CheckedContinuation<Void, Never>] = []
    func load(_ request: URLRequest) async throws -> ResourceResponse {
        paths.append(request.url!.path)
        await withCheckedContinuation { gates.append($0) }
        try Task.checkCancellation()
        return ResourceResponse(data: Data(), finalURL: request.url!, statusCode: 200)
    }
    func release() { if !gates.isEmpty { gates.removeFirst().resume() } }
}
actor CancellableSleeper: RequestSleeper {
    var started = false
    func sleep(seconds: Double) async throws { started = true; try await Task.sleep(for: .seconds(30)) }
}
public let httpClientChecks: [Check] = [
    Check("HTTPClientTests.downloadBudgetLeavesRoomForVisibleReading") {
        let transport = BlockingTransport(); let client = URLSessionHTTPClient(transport: transport)
        let jobs = (0..<6).map { index in Task { _ = try await client.send(ResourceRequest(url: URL(string: "https://a.test/download/\(index)")!), sourceID: Samples.sourceA.id, priority: .download) } }
        for _ in 0..<40 { if await transport.paths.count >= 6 { break }; try await Task.sleep(for: .milliseconds(1)) }
        let reading = Task { _ = try await client.send(ResourceRequest(url: URL(string: "https://a.test/visible")!), sourceID: Samples.sourceA.id, priority: .reading) }
        for _ in 0..<40 { if await transport.paths.count >= 7 { break }; try await Task.sleep(for: .milliseconds(1)) }
        let observed = await transport.paths
        for job in jobs { job.cancel() }; reading.cancel()
        for _ in observed { await transport.release() }
        for job in jobs { _ = try? await job.value }; _ = try? await reading.value
        try expect(observed.count == 7 && observed.contains("/visible"), "Six downloads can overlap while a visible page still starts without waiting for them")
    },
    Check("HTTPClientTests.limitedConcurrencyAndPriority") {
        let transport = SequenceTransport([])
        let client = URLSessionHTTPClient(transport: transport)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { _ = try await client.send(ResourceRequest(url: URL(string: "https://a.test/\(i)")!), sourceID: Samples.sourceA.id, priority: i == 19 ? .reading : .prefetch) }
            }
            try await group.waitForAll()
        }
        let peak = await transport.maximum
        try expect(peak <= 7 && peak > 0, "Real scheduler must enforce per-source request limit")
        let global = SequenceTransport([]); let shared = URLSessionHTTPClient(transport: global)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<40 { group.addTask { _ = try await shared.send(ResourceRequest(url: URL(string: "https://host\(i).test/")!), sourceID: SourceID(), priority: .search) } }
            try await group.waitForAll()
        }
        try expect(await global.maximum <= 10, "Real scheduler must enforce global limit")
    },
    Check("HTTPClientTests.queuedReadingPrecedesPrefetch") {
        let transport = BlockingTransport()
        let client = URLSessionHTTPClient(transport: transport, scheduler: RequestScheduler(globalLimit: 1, sourceLimit: 1))
        func job(_ path: String, _ priority: RequestPriority) -> Task<Void, Error> {
            Task { _ = try await client.send(ResourceRequest(url: URL(string: "https://a.test/" + path)!), sourceID: Samples.sourceA.id, priority: priority) }
        }
        let first = job("first", .reading)
        while await transport.paths.count < 1 { await Task.yield() }
        let background = job("background", .prefetch)
        let reading = job("reading", .reading)
        // Allow both tasks to reach the scheduler while the transport is held.
        for _ in 0..<500 { await Task.yield() }
        await transport.release()
        while await transport.paths.count < 2 { await Task.yield() }
        try expect(await transport.paths[1] == "/reading", "Queued visible page must precede speculative fetch")
        await transport.release()
        while await transport.paths.count < 3 { await Task.yield() }
        await transport.release()
        try await first.value; try await reading.value; try await background.value
    },
    Check("HTTPClientTests.cancelDuringBackoffReleasesSlot") {
        let response = ResourceResponse(data: Data(), finalURL: Samples.sourceA.baseURL, statusCode: 429)
        let sleeper = CancellableSleeper()
        let client = URLSessionHTTPClient(transport: SequenceTransport([response]), sleeper: sleeper, scheduler: RequestScheduler(globalLimit: 1))
        let job = Task { _ = try await client.send(ResourceRequest(url: Samples.sourceA.baseURL), sourceID: Samples.sourceA.id, priority: .reading) }
        while await !sleeper.started { await Task.yield() }
        job.cancel()
        do { try await job.value; throw CheckFailure(description: "Expected cancellation during backoff") } catch is CancellationError { }
        let result = try await client.send(ResourceRequest(url: Samples.sourceA.baseURL), sourceID: Samples.sourceA.id, priority: .reading)
        try expect(result.statusCode == 200, "Backoff must not retain a slot")
    },
    Check("HTTPClientTests.credentialsAreSourceAndOriginScoped") {
        let contexts = AccessContextStore()
        let id = try await contexts.register(sourceID: Samples.sourceA.id, originURL: Samples.sourceA.baseURL, headers: ["Cookie": "session=secret"])
        try expect(await contexts.headers(for: id, sourceID: Samples.sourceA.id, url: Samples.sourceA.baseURL)["Cookie"] != nil, "Registered origin should receive credentials")
        try expect(await contexts.headers(for: id, sourceID: Samples.sourceB.id, url: Samples.sourceA.baseURL).isEmpty, "Other source cannot use context")
        try expect(await contexts.headers(for: id, sourceID: Samples.sourceA.id, url: URL(string: "https://cdn.test/image")!).isEmpty, "CDN must not receive source credentials")
    },
    Check("HTTPClientTests.retryAfterAndCancellation") {
        let response = ResourceResponse(data: Data(), finalURL: Samples.sourceA.baseURL, statusCode: 429, headers: ["Retry-After": "10"])
        let transport = SequenceTransport([response, response, response, response]); let sleeper = ImmediateSleeper()
        let client = URLSessionHTTPClient(transport: transport, sleeper: sleeper)
        do { _ = try await client.send(ResourceRequest(url: Samples.sourceA.baseURL), sourceID: Samples.sourceA.id, priority: .reading); throw CheckFailure(description: "Expected rate limit") }
        catch MangaError.accessRestricted(let status) { try expect(status == 429, "Rate limit classification") }
        try expect(await sleeper.delays == [10, 10], "At most two retries with Retry-After")
        let job = Task { _ = try await client.send(ResourceRequest(url: Samples.sourceA.baseURL), sourceID: Samples.sourceA.id, priority: .prefetch) }
        job.cancel()
        do { try await job.value; throw CheckFailure(description: "Expected cancellation") } catch is CancellationError { }
    },
    Check("HTTPClientTests.crossOriginRedirectDropsSecrets") {
        var request = URLRequest(url: URL(string: "https://cdn.test/image")!)
        request.setValue("secret", forHTTPHeaderField: "Authorization")
        request.setValue("session=secret", forHTTPHeaderField: "Cookie")
        request.setValue("custom-secret", forHTTPHeaderField: "X-Token")
        let sanitized = RedirectPolicy.sanitize(request, from: URL(string: "https://a.test/")!)
        try expect(sanitized.value(forHTTPHeaderField: "Authorization") == nil && sanitized.value(forHTTPHeaderField: "Cookie") == nil && sanitized.value(forHTTPHeaderField: "X-Token") == nil, "Cross-origin redirects cannot forward credentials")
    },
    Check("HTTPClientTests.sourceErrorsStayDistinct") {
        let client = URLSessionHTTPClient(transport: SequenceTransport([ResourceResponse(data: Data(), finalURL: Samples.sourceA.baseURL, statusCode: 403)]))
        do { _ = try await client.send(ResourceRequest(url: Samples.sourceA.baseURL), sourceID: Samples.sourceA.id, priority: .probe); throw CheckFailure(description: "403 must fail") }
        catch MangaError.accessRestricted(let status) { try expect(status == 403, "Preserve HTTP status") }
        try expect(NetworkErrorMapper.map(URLError(.timedOut)) == .timedOut, "Timeout classification")
        try expect(NetworkErrorMapper.map(URLError(.notConnectedToInternet)) == .networkUnavailable, "Offline classification")
    }
]
