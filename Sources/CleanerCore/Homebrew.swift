import Foundation

/// A formula (command-line tool or library) or cask (app) installed with Homebrew.
public struct BrewPackage: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case formula, cask }

    public let kind: Kind
    /// The name Homebrew uses (`gh`, `google-chrome`).
    public let token: String
    public let displayName: String
    public let summary: String?
    public let installedVersion: String
    /// Newer version Homebrew knows about; nil when up to date.
    public let latestVersion: String?
    /// Installed because the user asked for it, not as another formula's dependency.
    public let isRequested: Bool
    /// The app updates itself (Homebrew then doesn't report it as outdated).
    public let autoUpdates: Bool
    /// For casks: where the app should be.
    public let appPath: String?
    /// A cask whose app is no longer where Homebrew put it.
    public let isAppMissing: Bool

    public var id: String { (kind == .cask ? "cask:" : "formula:") + token }
    public var isOutdated: Bool { latestVersion != nil }

    public init(kind: Kind, token: String, displayName: String, summary: String?, installedVersion: String,
                latestVersion: String?, isRequested: Bool, autoUpdates: Bool, appPath: String?, isAppMissing: Bool) {
        self.kind = kind
        self.token = token
        self.displayName = displayName
        self.summary = summary
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.isRequested = isRequested
        self.autoUpdates = autoUpdates
        self.appPath = appPath
        self.isAppMissing = isAppMissing
    }
}

/// Talks to the `brew` command. Listing is read-only; changes are explicit commands the user starts.
public struct Homebrew: Sendable {
    public let executable: String
    public let runner: CommandRunner

    public init?(runner: CommandRunner = ProcessRunner(), executable: String? = Homebrew.locate()) {
        guard let executable else { return nil }
        self.executable = executable
        self.runner = runner
    }

    /// Apple silicon and Intel install locations.
    public static func locate() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Keeps listing fast and output plain; brew's own bin first so it finds its tools.
    public var environment: [String: String] {
        let bin = (executable as NSString).deletingLastPathComponent
        return [
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_COLOR": "1",
            "PATH": "\(bin):/usr/bin:/bin:/usr/sbin:/sbin",
        ]
    }

    public func installed() async -> [BrewPackage] {
        async let info = runner.run(executable, ["info", "--json=v2", "--installed"], environment: environment)
        async let outdated = runner.run(executable, ["outdated", "--json=v2"], environment: environment)
        return Self.parse(info: await info.output, outdated: await outdated.output)
    }

    static func parse(info: String, outdated: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [BrewPackage] {
        guard let data = info.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let latest = latestVersions(outdated)

        let formulae = (root["formulae"] as? [[String: Any]] ?? []).compactMap { formula -> BrewPackage? in
            guard let name = formula["name"] as? String,
                  let installed = (formula["installed"] as? [[String: Any]])?.last
            else { return nil }
            return BrewPackage(
                kind: .formula, token: name, displayName: name, summary: formula["desc"] as? String,
                installedVersion: installed["version"] as? String ?? "",
                latestVersion: latest["formula:" + name],
                isRequested: installed["installed_on_request"] as? Bool ?? true,
                autoUpdates: false, appPath: nil, isAppMissing: false)
        }
        let casks = (root["casks"] as? [[String: Any]] ?? []).compactMap { cask -> BrewPackage? in
            guard let token = cask["token"] as? String else { return nil }
            let appPath = (cask["artifacts"] as? [[String: Any]] ?? []).lazy.compactMap { artifact -> String? in
                guard artifact["app"] != nil else { return nil }
                if let target = artifact["target"] as? String { return target }
                return (artifact["app"] as? [Any])?.first.flatMap { $0 as? String }.map { "/Applications/" + $0 }
            }.first
            return BrewPackage(
                kind: .cask, token: token, displayName: (cask["name"] as? [String])?.first ?? token,
                summary: cask["desc"] as? String, installedVersion: cask["installed"] as? String ?? "",
                latestVersion: latest["cask:" + token], isRequested: true,
                autoUpdates: cask["auto_updates"] as? Bool ?? false,
                appPath: appPath, isAppMissing: appPath.map { !fileExists($0) } ?? false)
        }
        return (casks + formulae).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// `brew outdated --json=v2` → "formula:name"/"cask:token" → newest version.
    static func latestVersions(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var result: [String: String] = [:]
        for (key, prefix) in [("formulae", "formula:"), ("casks", "cask:")] {
            for entry in root[key] as? [[String: Any]] ?? [] {
                if let name = entry["name"] as? String, let version = entry["current_version"] as? String {
                    result[prefix + name] = version
                }
            }
        }
        return result
    }

    /// What `brew cleanup` would free, from its dry run ("… would free approximately 74.9MB …").
    public func cleanupEstimate() async -> Int64? {
        Self.parseCleanupEstimate(await runner.run(executable, ["cleanup", "--dry-run"], environment: environment).output)
    }

    static func parseCleanupEstimate(_ output: String) -> Int64? {
        guard let line = output.split(separator: "\n").last(where: { $0.contains("would free approximately") }),
              let range = line.range(of: "approximately ")
        else { return nil }
        let amount = line[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        for (unit, factor) in units where amount.hasSuffix(unit) {
            guard let value = Double(amount.dropLast(unit.count)) else { return nil }
            return Int64(value * factor)
        }
        return nil
    }

    // MARK: Commands the user starts

    public static func upgradeArguments(_ package: BrewPackage?) -> [String] {
        guard let package else { return ["upgrade"] }
        return package.kind == .cask ? ["upgrade", "--cask", package.token] : ["upgrade", package.token]
    }

    /// Never `--zap`: for a browser that would take the user's profile (bookmarks, history) without asking.
    /// Leftovers are Ferah's job instead, listed for review and moved to the Trash.
    public static func uninstallArguments(_ package: BrewPackage) -> [String] {
        package.kind == .cask ? ["uninstall", "--cask", package.token] : ["uninstall", package.token]
    }

    public static func reinstallArguments(_ package: BrewPackage) -> [String] {
        package.kind == .cask ? ["reinstall", "--cask", package.token] : ["reinstall", package.token]
    }

    /// Where Homebrew keeps its record of an installed cask: `<prefix>/Caskroom/<token>`.
    /// nil unless the token is a plain cask name, so nothing else can ever be addressed.
    public func caskroomRecord(for package: BrewPackage) -> URL? {
        guard package.kind == .cask, !package.token.isEmpty,
              package.token.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || "-@._".contains($0)) }),
              !package.token.hasPrefix(".")
        else { return nil }
        let prefix = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent()
        let record = prefix.appending(path: "Caskroom").appending(path: package.token)
        return FileManager.default.fileExists(atPath: record.path) ? record : nil
    }

    public static let updateArguments = ["update"]
    public static let cleanupArguments = ["cleanup", "--prune=all"]
    public static let autoremoveArguments = ["autoremove"]
}
