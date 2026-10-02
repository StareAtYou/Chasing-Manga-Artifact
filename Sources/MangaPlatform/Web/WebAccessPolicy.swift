import Foundation
import MangaCore
public enum WebAccessPolicy {
    public static func permits(_ url: URL, source: Source) -> Bool { WebOrigin(url) != nil && WebOrigin(url) == WebOrigin(source.baseURL) && url.user == nil && url.password == nil }
    public static func diagnostic(url: URL, status: Int) -> String { "\(url.host ?? "source") \(status)" }
}
@MainActor public final class RenderLifecycle {
    private var pending: (UUID, CheckedContinuation<RenderedPage, Error>)?
    public var isWaiting: Bool { pending != nil }
    public init() { }
    public func wait(token: UUID) async throws -> RenderedPage {
        try Task.checkCancellation()
        guard pending == nil else { throw MangaError.unsupported("该源页面正在加载") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending = (token, $0) }
        } onCancel: {
            Task { @MainActor in self.finish(token: token, result: .failure(CancellationError())) }
        }
    }
    public func finish(token: UUID, result: Result<RenderedPage, Error>) {
        guard let pending, pending.0 == token else { return }
        self.pending = nil; pending.1.resume(with: result)
    }
    public func cancel() { if let token = pending?.0 { finish(token: token, result: .failure(CancellationError())) } }
}
