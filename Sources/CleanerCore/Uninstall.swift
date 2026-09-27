import Foundation

public struct InstalledApp: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let bundleIdentifier: String?
    public let version: String?
    /// The binary's name; crash reports are named after it.
    public let executableName: String?

    public var id: URL { url }

    /// Apple's own apps are part of macOS: never uninstalled, and their data is never offered for removal.
    public var isAppleApp: Bool { bundleIdentifier.map(TrashPolicy.isAppleName) ?? false }

    public init(url: URL) {
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary ?? [:]
        self.url = url
        self.name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        self.bundleIdentifier = bundle?.bundleIdentifier
        self.version = info["CFBundleShortVersionString"] as? String
        self.executableName = info["CFBundleExecutable"] as? String
    }
}

/// Finds files an app leaves behind, in the user's Library and in /Library. Read-only.
public enum LeftoverFinder {
    struct Location {
        enum Base { case home, system }
        enum Match { case bundleID, crashReport }

        let base: Base
        let path: String
        /// Label for items named exactly after the bundle identifier; looser matches always need review.
        let safety: SafetyLabel
        /// Also match folders named after the app, not just its bundle identifier.
        var matchesName = false
        var match = Match.bundleID
    }

    static let locations: [Location] = [
        Location(base: .home, path: "Library/Application Support", safety: .appData, matchesName: true),
        Location(base: .home, path: "Library/Containers", safety: .appData),
        Location(base: .home, path: "Library/Group Containers", safety: .appData),
        Location(base: .home, path: "Library/Application Scripts", safety: .appData),
        Location(base: .home, path: "Library/Caches", safety: .regenerates, matchesName: true),
        Location(base: .home, path: "Library/WebKit", safety: .regenerates),
        Location(base: .home, path: "Library/HTTPStorages", safety: .regenerates),
        Location(base: .home, path: "Library/Preferences", safety: .safe),
        Location(base: .home, path: "Library/Preferences/ByHost", safety: .safe),
        Location(base: .home, path: "Library/Saved Application State", safety: .safe),
        Location(base: .home, path: "Library/Cookies", safety: .safe),
        Location(base: .home, path: "Library/Logs", safety: .safe, matchesName: true),
        Location(base: .home, path: "Library/Logs/DiagnosticReports", safety: .safe, match: .crashReport),
        Location(base: .home, path: "Library/LaunchAgents", safety: .appData),
        // System-wide leftovers from installers; moving them asks for an administrator password.
        Location(base: .system, path: "Library/Application Support", safety: .appData, matchesName: true),
        Location(base: .system, path: "Library/Caches", safety: .regenerates),
        Location(base: .system, path: "Library/Preferences", safety: .safe),
        Location(base: .system, path: "Library/LaunchAgents", safety: .appData),
        Location(base: .system, path: "Library/LaunchDaemons", safety: .appData),
        Location(base: .system, path: "Library/PrivilegedHelperTools", safety: .appData),
    ]

    /// Files named exactly `<bundle id>.<extension>` that belong to the app itself.
    static let ownFileExtensions: Set<String> = ["plist", "savedstate", "binarycookies"]
    static let crashReportExtensions: Set<String> = ["ips", "crash", "diag", "hang", "spin"]

    /// The app bundle first, then its leftovers, largest first. Apple apps get no leftovers.
    /// `systemRoot` is "/" except in tests.
    public static func find(for app: InstalledApp, home: URL, systemRoot: URL = URL(fileURLWithPath: "/")) -> ModuleResult {
        let log = UnreadableLog()
        let appItem = ScanItem(url: app.url, bytes: FileWalker.allocatedSize(of: app.url, log: log), safety: .review)
        guard !app.isAppleApp else { return ModuleResult(items: [appItem], unreadable: log.urls) }

        var leftovers: [ScanItem] = []
        var seen: Set<URL> = [app.url]
        for location in locations {
            let base = location.base == .home ? home : systemRoot
            let folder = base.appending(path: location.path)
            for child in FileWalker.children(of: folder, log: log) where !seen.contains(child) {
                guard let safety = match(child.lastPathComponent, app: app, location: location) else { continue }
                seen.insert(child)
                leftovers.append(ScanItem(url: child, bytes: FileWalker.allocatedSize(of: child, log: log), safety: safety))
            }
        }
        // /Library is readable but some of its folders aren't; that's expected and not worth a notice.
        let unreadable = log.urls.filter { $0.path.hasPrefix(home.path) }
        return ModuleResult(items: [appItem] + leftovers.sorted { $0.bytes > $1.bytes }, unreadable: unreadable)
    }

    static func match(_ fileName: String, app: InstalledApp, location: Location) -> SafetyLabel? {
        let name = fileName.lowercased()
        if location.match == .crashReport {
            return isCrashReport(name, app: app) ? location.safety : nil
        }
        // Bundle identifiers without a dot are too generic to match safely.
        if let id = app.bundleIdentifier?.lowercased(), id.contains("."), !TrashPolicy.isAppleName(id) {
            // Exactly the app's own: its folder, its plist, its saved state, its group container.
            if name == id || name == "group." + id || isTeamPrefixed(name, id: id) {
                return location.safety
            }
            if name.hasPrefix(id + "."), ownFileExtensions.contains(String(name.dropFirst(id.count + 1))) {
                return location.safety
            }
            // Anything else starting with the identifier may be a sibling app (com.jetbrains.intellij.ce
            // next to com.jetbrains.intellij, Chrome Canary next to Chrome), so the user decides.
            if name.hasPrefix(id + ".") {
                return .review
            }
        }
        // Name matches are a guess, so the user always decides.
        let appName = app.name.lowercased()
        if location.matchesName, appName.count >= 3, name == appName {
            return .review
        }
        return nil
    }

    /// `Ferah-2026-09-27-120000.ips`, `Ferah_2026-09-27-120000_Mac.crash`: named after the executable.
    static func isCrashReport(_ name: String, app: InstalledApp) -> Bool {
        guard crashReportExtensions.contains((name as NSString).pathExtension) else { return false }
        let processNames = [app.executableName, app.name].compactMap { $0?.lowercased() }.filter { $0.count >= 3 }
        return processNames.contains { name.hasPrefix($0 + "-") || name.hasPrefix($0 + "_") }
    }

    /// `ABCDE12345.com.example.app`: a ten-character team ID, then the bundle identifier.
    static func isTeamPrefixed(_ name: String, id: String) -> Bool {
        guard name.hasSuffix("." + id) else { return false }
        let team = name.dropLast(id.count + 1)
        return team.count == 10 && team.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
