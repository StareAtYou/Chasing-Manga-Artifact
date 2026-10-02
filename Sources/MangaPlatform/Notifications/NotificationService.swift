import Foundation
import UserNotifications
import MangaCore
public final class NotificationService: NotificationDelivering, Sendable {
    public init() { }
    public func requestPermission() async throws -> Bool { try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    public func notify(workID: WorkID, chapters: [Chapter]) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { throw MangaError.unsupported("通知权限未授权，新增章节仍已保存") }
        let content = UNMutableNotificationContent(); content.title = "漫画更新了"; content.body = chapters.count == 1 ? chapters[0].title : "新增 \(chapters.count) 章"; content.sound = .default
        content.userInfo = ["workID": workID.key]
        let key = ContentDigest.hex(Data((workID.key + chapters.map { $0.id.key }.sorted().joined()).utf8))
        try await center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }
}
