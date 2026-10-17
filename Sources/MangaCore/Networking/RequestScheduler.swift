import Foundation

public enum RequestPriority: Int, Codable, Sendable, Comparable {
    case reading, probe, search, download, prefetch
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public actor RequestScheduler {
    private struct Waiting {
        let id: UUID
        let source: SourceID
        let priority: RequestPriority
        let continuation: CheckedContinuation<UUID, Error>
    }
    private var waiting: [Waiting] = []
    private struct Active { let source: SourceID; let priority: RequestPriority }
    private var active: [UUID: Active] = [:]
    private let globalLimit: Int
    private let sourceLimit: Int
    public init(globalLimit: Int = 10, sourceLimit: Int = 7) {
        self.globalLimit = max(1, globalLimit); self.sourceLimit = max(1, sourceLimit)
    }
    public func acquire(sourceID: SourceID, priority: RequestPriority) async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append(Waiting(id: id, source: sourceID, priority: priority, continuation: continuation))
                drain()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    public func release(_ id: UUID) { active.removeValue(forKey: id); drain() }
    private func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        }
        // Granted leases are released by the caller, including the grant/cancel race.
    }
    private func drain() {
        while active.count < globalLimit {
            let eligible = waiting.indices.filter { index in
                let item = waiting[index]
                let source = active.values.filter { $0.source == item.source }
                guard source.count < sourceLimit else { return false }
                if item.priority >= .download {
                    // Background images use more parallelism without occupying every
                    // slot needed by a newly visible page or an interactive search.
                    return active.values.filter { $0.priority >= .download }.count < max(1, globalLimit - 2)
                        && source.filter { $0.priority >= .download }.count < max(1, sourceLimit - 1)
                }
                return true
            }
            guard let index = eligible.min(by: { waiting[$0].priority < waiting[$1].priority }) else { return }
            let item = waiting.remove(at: index)
            active[item.id] = Active(source: item.source, priority: item.priority)
            item.continuation.resume(returning: item.id)
        }
    }
}
