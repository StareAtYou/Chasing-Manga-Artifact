import UIKit
@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    private static var handlers: [() -> Void] = []
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == "com.chasingmanga.local.download" else { completionHandler(); return }
        Self.handlers.append(completionHandler)
    }
    static func finishEvents() { let current = handlers; handlers.removeAll(); current.forEach { $0() } }
}
