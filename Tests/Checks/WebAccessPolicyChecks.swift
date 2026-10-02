import Foundation
import MangaCore
import MangaPlatform
public let webAccessPolicyChecks: [Check] = [
    Check("WebAccessPolicyTests.sourceContextsRemainSeparate") {
        let contexts = AccessContextStore()
        let first = try await contexts.register(sourceID: Samples.sourceA.id, originURL: Samples.sourceA.baseURL, headers: ["Cookie": "a=secret"])
        let second = try await contexts.register(sourceID: Samples.sourceB.id, originURL: Samples.sourceB.baseURL, headers: ["Cookie": "b=secret"])
        try expect(await contexts.headers(for: first, sourceID: Samples.sourceB.id, url: Samples.sourceB.baseURL).isEmpty, "No cross-source cookies")
        try expect(await contexts.headers(for: second, sourceID: Samples.sourceB.id, url: Samples.sourceB.baseURL)["Cookie"] == "b=secret", "Correct context")
    },
    Check("WebAccessPolicyTests.unrelatedNavigationDoesNotCreateBinding") {
        try expect(WebAccessPolicy.permits(URL(string: "https://a.test/chapter/1")!, source: Samples.sourceA), "Same-source navigation permitted")
        try expect(!WebAccessPolicy.permits(Samples.sourceB.baseURL, source: Samples.sourceA), "External navigation cannot change source")
        try expect(!WebAccessPolicy.permits(URL(string: "file:///etc/passwd")!, source: Samples.sourceA), "Local files not source content")
    },
    Check("WebAccessPolicyTests.renderTimeoutAndCancellation") {
        let lifecycle = await RenderLifecycle()
        let token = UUID()
        let task = Task { @MainActor in try await lifecycle.wait(token: token) }
        while await !lifecycle.isWaiting { await Task.yield() }
        await lifecycle.finish(token: token, result: .failure(MangaError.timedOut))
        do { _ = try await task.value; throw CheckFailure(description: "Expected render timeout") } catch MangaError.timedOut { }
        let cancelled = Task { @MainActor in try await lifecycle.wait(token: UUID()) }
        while await !lifecycle.isWaiting { await Task.yield() }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw CheckFailure(description: "Expected cancellation") } catch is CancellationError { }
        try expect(await !lifecycle.isWaiting, "Cancellation clears continuation")
    },
    Check("WebAccessPolicyTests.credentialsAreNotLogged") {
        let url = URL(string: "https://a.test/reader?token=secret&signature=private#secret")!
        let description = WebAccessPolicy.diagnostic(url: url, status: 403)
        try expect(!description.contains("secret") && !description.contains("private") && description.contains("403"), "Diagnostics must omit query and fragment")
    }
]
