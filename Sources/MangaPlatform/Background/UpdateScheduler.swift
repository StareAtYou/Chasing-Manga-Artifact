import Foundation
import MangaCore
#if os(iOS)
import BackgroundTasks
#endif
@MainActor public final class UpdateScheduler {
    public static let identifier = "com.chasingmanga.local.refresh"
    public var didCheck: (@MainActor () async -> Void)?
    private let updates: UpdateService
    private var running: Task<Void, Never>?
    private var periodic: Task<Void, Never>?
    public init(updates: UpdateService) { self.updates = updates }
    public func onAppActive() {
        checkNow()
        #if os(macOS)
        guard periodic == nil else { return }
        periodic = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30 * 60)) } catch { return }
                self?.checkNow()
            }
        }
        #else
        scheduleNext()
        #endif
    }
    public func checkNow() {
        guard running == nil else { return }
        running = Task { @MainActor [weak self] in
            guard let self else { return }
            let ids = (try? await updates.followedIDs()) ?? []
            _ = await updates.check(sourceWorkIDs: ids); await didCheck?(); running = nil
        }
    }
    public func stop() { running?.cancel(); periodic?.cancel(); running = nil; periodic = nil }
    public func scheduleNext() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier); request.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }
    #if os(iOS)
    public func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: nil) { [weak self] task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in self?.handle(refresh) }
        }
    }
    private func handle(_ task: BGAppRefreshTask) {
        scheduleNext()
        let job = Task { @MainActor [weak self] in
            guard let self else { task.setTaskCompleted(success: false); return }
            let ids = (try? await updates.followedIDs()) ?? []
            let results = await updates.check(sourceWorkIDs: ids)
            await didCheck?()
            task.setTaskCompleted(success: !Task.isCancelled && results.allSatisfy { $0.error == nil })
        }
        task.expirationHandler = { job.cancel() }
    }
    #endif
}
