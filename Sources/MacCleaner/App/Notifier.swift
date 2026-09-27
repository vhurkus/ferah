import AppKit
import CleanerCore
@preconcurrency import UserNotifications

extension Notification.Name {
    /// Posted with the trashed app's path when the user clicks a leftovers notification.
    static let showTrashedApp = Notification.Name("FerahShowTrashedApp")
}

/// Local notifications: leftovers of apps dragged to the Trash, and low disk space.
@MainActor
enum Notifier {
    nonisolated static let trashedAppKey = "trashedApp"

    static func leftovers(of trashed: TrashedApp) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(trashed.app.name) left \(trashed.leftovers.totalBytes.byteString) behind")
        content.body = String(localized: "The app is in the Trash, but its files are still in your Library. Click to remove them.")
        content.userInfo = [trashedAppKey: trashed.app.url.path]
        post(content, id: "leftovers-" + trashed.app.url.path)
    }

    static func lowDiskSpace(available: Int64) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Your Mac is running out of space")
        content.body = String(localized: "\(available.byteString) left. Open Ferah to see what you can remove.")
        post(content, id: "low-disk")
    }

    private static func post(_ content: UNMutableNotificationContent, id: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}

/// Routes notification clicks back into the app.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let path = response.notification.request.content.userInfo[Notifier.trashedAppKey] as? String
        await MainActor.run {
            NSApp.activate()
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            if let path { NotificationCenter.default.post(name: .showTrashedApp, object: path) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
