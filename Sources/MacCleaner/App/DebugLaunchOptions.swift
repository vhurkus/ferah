#if DEBUG
import AppKit

/// Launch arguments for screenshots, e.g. `-UIAppearance dark -UIWindowSize 900x600 -UIAutoScan YES -UIScreen apps -UIHome /path/to/fixture`.
@MainActor
enum DebugLaunchOptions {
    static func apply(to model: AppModel, select: (SidebarItem) -> Void) {
        let defaults = UserDefaults.standard
        if let fixtureHome = defaults.string(forKey: "UIHome") {
            model.useFixtureHome(URL(fileURLWithPath: fixtureHome, isDirectory: true))
        }
        switch defaults.string(forKey: "UIAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if let size = defaults.string(forKey: "UIWindowSize")?.split(separator: "x").compactMap({ Double($0) }),
           size.count == 2 {
            DispatchQueue.main.async {
                guard let window = NSApp.windows.first else { return }
                window.setContentSize(NSSize(width: size[0], height: size[1]))
                window.center()
            }
        }
        switch defaults.string(forKey: "UIScreen") {
        case "storage": select(.storage)
        case "caches": select(.module(.caches))
        case "developer": select(.module(.developer))
        case "largeFiles": select(.module(.largeFiles))
        case "apps": select(.module(.apps))
        default: break
        }
        if defaults.bool(forKey: "UIAutoScan") {
            model.scan()
        }
    }
}
#endif
