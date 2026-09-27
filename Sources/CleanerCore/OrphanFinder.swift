import CoreServices
import Foundation

/// Finds files left behind by apps that are no longer installed. Read-only.
/// Everything it finds needs review: an identifier with no installed app is strong evidence, not proof.
public enum OrphanFinder {
    /// Library folders whose items are named after bundle identifiers.
    static let folders = [
        "Library/Application Support", "Library/Containers", "Library/Group Containers", "Library/Application Scripts",
        "Library/Caches", "Library/HTTPStorages", "Library/WebKit", "Library/Preferences",
        "Library/Saved Application State", "Library/Cookies", "Library/Logs", "Library/LaunchAgents",
    ]

    /// Top-level domains that start a reverse-DNS bundle identifier.
    static let identifierPrefixes: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "co", "me", "de", "uk", "fr", "tr", "jp", "cn", "ru", "ch",
        "nl", "se", "no", "fi", "it", "es", "at", "be", "ca", "au", "us", "info", "tv", "cc", "ai", "so", "sh",
    ]

    /// Command-line tools that keep reverse-DNS named caches but aren't apps, so "removed app" would be wrong.
    static let toolPrefixes = ["org.swift.", "org.llvm.", "org.python.", "org.nodejs.", "org.rust-lang.", "org.golang."]

    /// - Parameters:
    ///   - installedIdentifiers: bundle identifiers of apps found on this Mac (lowercased), from the apps scan.
    ///   - isInstalled: asks the system whether an app with this identifier exists anywhere.
    public static func find(
        home: URL,
        installedIdentifiers: Set<String>,
        isInstalled: (String) -> Bool = isRegisteredApp
    ) -> ModuleResult {
        let log = UnreadableLog()
        var items: [ScanItem] = []
        var verdicts: [String: Bool] = [:]

        for folder in folders {
            for child in FileWalker.children(of: home.appending(path: folder), log: log) {
                guard let id = identifier(in: child.lastPathComponent), !TrashPolicy.isAppleName(id) else { continue }
                let key = id.lowercased()
                guard !toolPrefixes.contains(where: { key.hasPrefix($0) }) else { continue }
                // Extensions and helpers of installed apps (com.foo.app.helper) belong to them.
                let belongsToInstalledApp = installedIdentifiers.contains {
                    key == $0 || key.hasPrefix($0 + ".") || $0.hasPrefix(key + ".")
                }
                guard !belongsToInstalledApp else { continue }
                // Identifiers are case-sensitive to Launch Services, so ask with the name as written.
                let orphaned = verdicts[key] ?? !isInstalled(id)
                verdicts[key] = orphaned
                guard orphaned else { continue }
                items.append(ScanItem(url: child, bytes: FileWalker.allocatedSize(of: child, log: log), safety: .review))
            }
        }
        let unreadable = log.urls.filter { !$0.lastPathComponent.hasPrefix("com.apple.") }
        return ModuleResult(items: items.sorted { $0.bytes > $1.bytes }, unreadable: unreadable)
    }

    /// The bundle identifier an item is named after, as written, or nil if its name isn't one.
    /// Handles `id`, `id.plist`, `id.savedState`, `id.binarycookies`, `group.id` and `TEAMID.id`.
    static func identifier(in fileName: String) -> String? {
        var name = fileName
        for suffix in [".plist", ".savedstate", ".binarycookies"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        if name.lowercased().hasPrefix("group.") { name = String(name.dropFirst("group.".count)) }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        if let first = parts.first, first.count == 10, first.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
           parts.count >= 4 {
            name = parts.dropFirst().joined(separator: ".")
        }
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 3, let first = components.first, identifierPrefixes.contains(first.lowercased()),
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } })
        else { return nil }
        return name
    }

    /// Launch Services knows every app on the Mac, wherever it is, including ones in Downloads or build folders.
    public static func isRegisteredApp(_ identifier: String) -> Bool {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, nil)?.takeRetainedValue() as? [URL]
        else { return false }
        return !urls.isEmpty
    }
}
