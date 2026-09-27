import Foundation

/// The last line of defence before anything is moved to the Trash.
/// Every path is checked here, whatever screen asked for it.
public enum TrashPolicy {
    public enum Rejection: Error, Equatable, Sendable {
        case missing
        /// Not inside the home folder and not a third-party app.
        case outsideAllowedLocations
        /// A folder the system or the user depends on as a whole (~/Library, ~/Desktop, ~/Library/Caches …),
        /// or one holding data that can't be rebuilt (~/Library/Keychains, iCloud Drive …).
        case protectedLocation
        /// Apple's own apps are part of macOS.
        case systemApp
        /// Settings and data that belong to macOS or Apple's apps.
        case systemData
    }

    /// Library folders holding data that can't be rebuilt or lives in the cloud; nothing inside them is ever removed.
    static let sensitiveLibraryFolders: Set<String> = [
        "Keychains", "Mobile Documents", "CloudStorage", "Mail", "Messages", "Accounts", "Calendars", "Safari", "Photos",
    ]

    /// Library folders where Apple's items are disposable: caches and logs rebuild themselves.
    static let appleDisposableFolders: Set<String> = ["Caches", "Logs"]

    /// Folders in /Library where installers leave an app's files. Only their direct, non-Apple items may go.
    static let systemLeftoverFolders: Set<String> = [
        "Application Support", "Caches", "Preferences", "LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools",
    ]

    /// `systemRoot` is "/" except in tests.
    public static func check(
        _ url: URL, home: URL, applicationRoots: [URL], systemRoot: URL = URL(fileURLWithPath: "/")
    ) -> Rejection? {
        guard FileManager.default.fileExists(atPath: url.path) || isSymlink(url) else { return .missing }
        let target = url.standardizedFileURL.resolvingSymlinksInPath()

        if target.pathExtension == "app" {
            if isAppleBundle(target) { return .systemApp }
            if isInApplicationFolder(target, roots: applicationRoots) { return nil }
        }
        if let rejection = checkSystemLeftover(target.pathComponents, systemRoot: systemRoot) {
            return rejection == .outsideAllowedLocations ? checkHomeItem(target.pathComponents, home: home) : rejection
        }
        return nil
    }

    /// `nil` for an allowed /Library item, `.outsideAllowedLocations` when the path isn't one at all.
    static func checkSystemLeftover(_ parts: [String], systemRoot: URL) -> Rejection? {
        let rootParts = systemRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard parts.count == rootParts.count + 3,
              Array(parts.prefix(rootParts.count)) == rootParts,
              parts[rootParts.count] == "Library",
              systemLeftoverFolders.contains(parts[rootParts.count + 1])
        else { return .outsideAllowedLocations }
        return isAppleName(parts[rootParts.count + 2]) ? .systemData : nil
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// Directly in an application folder, or one plain subfolder down (e.g. /Applications/Adobe X/X.app).
    /// Never an app nested inside another bundle: that one is part of its host app.
    static func isInApplicationFolder(_ target: URL, roots: [URL]) -> Bool {
        let parts = target.pathComponents
        return roots.contains { root in
            let rootParts = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard (1...2).contains(parts.count - rootParts.count),
                  Array(parts.prefix(rootParts.count)) == rootParts
            else { return false }
            return parts.dropFirst(rootParts.count).dropLast().allSatisfy { !$0.contains(".") }
        }
    }

    static func checkHomeItem(_ parts: [String], home: URL) -> Rejection? {
        let homeParts = home.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard parts.count > homeParts.count, Array(parts.prefix(homeParts.count)) == homeParts else {
            return .outsideAllowedLocations
        }
        let relative = Array(parts.dropFirst(homeParts.count))
        // Top-level home items (Desktop, Library, Downloads …) and Library's own folders are never removed whole.
        if relative.count == 1 || (relative.first == "Library" && relative.count == 2) {
            return .protectedLocation
        }
        guard relative.first == "Library" else { return nil }
        if sensitiveLibraryFolders.contains(relative[1]) { return .protectedLocation }
        if !appleDisposableFolders.contains(relative[1]), isAppleName(relative[2]) { return .systemData }
        return nil
    }

    /// `com.apple.Safari`, `com.apple.Safari.plist`, `group.com.apple.notes`, `243LU875E5.groups.com.apple.podcasts` …
    public static func isAppleName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("com.apple.") || lower.contains(".com.apple.")
    }

    static func isAppleBundle(_ url: URL) -> Bool {
        Bundle(url: url)?.bundleIdentifier.map { isAppleName($0) } ?? false
    }
}
