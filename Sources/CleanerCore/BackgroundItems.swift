import Foundation

/// A launch agent or daemon: something macOS starts in the background, at login or at startup.
public struct BackgroundItem: Identifiable, Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        /// ~/Library/LaunchAgents: runs as this user; the user can manage it.
        case user
        /// /Library/LaunchAgents: runs as every user who logs in; changing it needs an administrator.
        case allUsers
        /// /Library/LaunchDaemons: runs as root at startup; changing it needs an administrator.
        case system
    }

    public let plist: URL
    public let label: String
    public let scope: Scope
    /// The program it runs, when the plist names one.
    public let program: String?
    public let runsAtLoad: Bool
    public let keepsAlive: Bool
    /// The app it belongs to, when that can be told.
    public let ownerName: String?
    public let ownerURL: URL?
    /// Turned off with `launchctl disable`.
    public var isDisabled: Bool
    /// Its program no longer exists, usually because its app was removed.
    public let isBroken: Bool

    public var id: URL { plist }

    public init(plist: URL, label: String, scope: Scope, program: String?, runsAtLoad: Bool, keepsAlive: Bool,
                ownerName: String?, ownerURL: URL?, isDisabled: Bool, isBroken: Bool) {
        self.plist = plist
        self.label = label
        self.scope = scope
        self.program = program
        self.runsAtLoad = runsAtLoad
        self.keepsAlive = keepsAlive
        self.ownerName = ownerName
        self.ownerURL = ownerURL
        self.isDisabled = isDisabled
        self.isBroken = isBroken
    }
}

/// Lists launch agents and daemons and says whose they are. Read-only; changes go through launchctl.
public struct BackgroundItemFinder: Sendable {
    public let runner: CommandRunner
    public let home: URL
    public let systemRoot: URL

    public init(runner: CommandRunner = ProcessRunner(), home: URL, systemRoot: URL = URL(fileURLWithPath: "/")) {
        self.runner = runner
        self.home = home
        self.systemRoot = systemRoot
    }

    /// - Parameter installedApps: apps found on this Mac, to name owners.
    public func find(installedApps: [InstalledApp]) async -> [BackgroundItem] {
        let userDisabled = Self.disabledLabels(in: await runner.run("/bin/launchctl", ["print-disabled", "gui/\(getuid())"]).output)
        let systemDisabled = Self.disabledLabels(in: await runner.run("/bin/launchctl", ["print-disabled", "system"]).output)

        let folders: [(URL, BackgroundItem.Scope)] = [
            (home.appending(path: "Library/LaunchAgents"), .user),
            (systemRoot.appending(path: "Library/LaunchAgents"), .allUsers),
            (systemRoot.appending(path: "Library/LaunchDaemons"), .system),
        ]
        return folders.flatMap { folder, scope in
            FileWalker.children(of: folder, log: UnreadableLog())
                .filter { $0.pathExtension == "plist" }
                .compactMap { plist in
                    Self.item(at: plist, scope: scope, installedApps: installedApps,
                              disabled: scope == .system ? systemDisabled : userDisabled)
                }
        }
        // Apple's own items aren't the user's business.
        .filter { !TrashPolicy.isAppleName($0.label) }
    }

    static func item(at plist: URL, scope: BackgroundItem.Scope, installedApps: [InstalledApp], disabled: Set<String>) -> BackgroundItem? {
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any], let label = info["Label"] as? String else { return nil }
        let arguments = info["ProgramArguments"] as? [String] ?? []
        let program = info["Program"] as? String ?? arguments.first
        // Launchers like `/usr/bin/open -W /Applications/X.app/…` name the app in a later argument.
        let appPath = ([program].compactMap { $0 } + arguments).first { $0.contains(".app") }
        let owner = Self.owner(label: label, program: appPath ?? program,
                               associated: info["AssociatedBundleIdentifiers"], installedApps: installedApps)
        let isBroken = program.map { $0.hasPrefix("/") && !FileManager.default.fileExists(atPath: $0) } ?? false
        return BackgroundItem(
            plist: plist, label: label, scope: scope, program: program,
            runsAtLoad: info["RunAtLoad"] as? Bool ?? false,
            keepsAlive: (info["KeepAlive"] as? Bool) ?? (info["KeepAlive"] is [String: Any]),
            ownerName: owner?.name, ownerURL: owner?.url,
            isDisabled: disabled.contains(label) || (info["Disabled"] as? Bool ?? false),
            isBroken: isBroken)
    }

    /// Whose item it is: the app it says it belongs to, the app its program lives in,
    /// or the one app from the same developer (same first two parts of the identifier).
    static func owner(label: String, program: String?, associated: Any?, installedApps: [InstalledApp]) -> InstalledApp? {
        let ids = (associated as? [String]) ?? (associated as? String).map { [$0] } ?? []
        if let app = installedApps.first(where: { app in ids.contains { $0.caseInsensitiveCompare(app.bundleIdentifier ?? "") == .orderedSame } }) {
            return app
        }
        if let program, let range = program.range(of: ".app/") ?? program.range(of: ".app", options: .backwards) {
            let bundlePath = String(program[..<range.lowerBound]) + ".app"
            if let app = installedApps.first(where: { $0.url.path == bundlePath }) { return app }
            if FileManager.default.fileExists(atPath: bundlePath) { return InstalledApp(url: URL(fileURLWithPath: bundlePath)) }
        }
        let vendor = label.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
        // An uninstaller from the same developer never owns the background work.
        let sameVendor = installedApps.filter {
            ($0.bundleIdentifier?.lowercased().split(separator: ".").prefix(2).joined(separator: ".")) == vendor
                && !$0.name.lowercased().contains("uninstall") && !($0.bundleIdentifier ?? "").lowercased().contains("uninstall")
        }
        if sameVendor.count == 1 { return sameVendor[0] }
        if let program {
            let parts = Set(program.split(separator: "/").map { $0.lowercased() })
            let byName = installedApps.filter { parts.contains($0.name.lowercased()) }
            if byName.count == 1 { return byName[0] }
        }
        return nil
    }

    /// Labels `launchctl print-disabled` reports as disabled.
    static func disabledLabels(in output: String) -> Set<String> {
        Set(output.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2, parts[1].trimmingCharacters(in: .whitespaces) == "disabled" else { return nil }
            return parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        })
    }

    // MARK: Changes

    /// Commands that stop an item and keep it from starting again; reversed by `enableCommands`.
    public static func disableCommands(for item: BackgroundItem) -> [[String]] {
        let domain = domain(for: item)
        return [
            ["/bin/launchctl", "bootout", domain, item.plist.path],
            ["/bin/launchctl", "disable", domain + "/" + item.label],
        ]
    }

    public static func enableCommands(for item: BackgroundItem) -> [[String]] {
        let domain = domain(for: item)
        return [
            ["/bin/launchctl", "enable", domain + "/" + item.label],
            ["/bin/launchctl", "bootstrap", domain, item.plist.path],
        ]
    }

    /// Whether changing it needs an administrator password.
    public static func needsAdministrator(_ item: BackgroundItem) -> Bool { item.scope == .system }

    static func domain(for item: BackgroundItem) -> String {
        item.scope == .system ? "system" : "gui/\(getuid())"
    }
}
