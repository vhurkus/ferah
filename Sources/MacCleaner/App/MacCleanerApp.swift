import AppKit
import SwiftUI
import UserNotifications

@main
struct MacCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(SettingsKeys.showInMenuBar) private var showInMenuBar = true

    var body: some Scene {
        // One window: opening Ferah from the menu bar brings it back instead of adding another.
        Window("Ferah", id: "main") {
            ContentView(model: .shared)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        Settings {
            SettingsView()
        }
        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarView(model: .shared)
        } label: {
            Image(systemName: "wind")
                .accessibilityLabel(Text("Ferah"))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notificationRouter = NotificationRouter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = notificationRouter
        MainActor.assumeIsolated { AppModel.shared.start() }
        // Needed when launched as a bare executable (`swift run`) rather than a bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// In the menu bar, Ferah keeps running without a window (watching the Trash, checking free space).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: SettingsKeys.showInMenuBar) as? Bool ?? true)
    }
}
