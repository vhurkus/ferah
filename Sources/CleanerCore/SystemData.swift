import Foundation

/// Something macOS files under "System Data" that the user can actually do something about.
public struct SystemDataItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Time Machine's local snapshots; removed with `tmutil deletelocalsnapshots`.
        case localSnapshots(dates: [String])
        /// An Xcode simulator runtime; removed with `simctl runtime delete`.
        case simulatorRuntime(identifier: String)
        /// Simulators whose runtime is gone; removed with `simctl delete unavailable`.
        case unavailableSimulators(count: Int)
        /// An iPhone or iPad backup made by Finder; moved to the Trash.
        case deviceBackup
        /// Photos and files received in Messages; managed in Messages itself.
        case messagesAttachments
        /// An "Install macOS …" app left in Applications; downloadable again from Apple.
        case macOSInstaller
        /// iPhone or iPad firmware Finder downloaded for an update or restore.
        case deviceFirmware
        /// A second copy of Xcode, besides the one command-line tools use.
        case extraXcode
        /// Instruments and loops for GarageBand and Logic; managed in those apps.
        case soundLibrary
        /// Attachments Mail saved when you opened them; Mail recreates them as needed.
        case mailDownloads
    }

    public let id: String
    public let kind: Kind
    public let title: String
    /// Secondary line: a date, a version, a device name.
    public let detail: String?
    /// nil when macOS doesn't report a size (snapshots).
    public let bytes: Int64?
    public let url: URL?
    public let lastUsed: Date?

    public init(id: String, kind: Kind, title: String, detail: String? = nil, bytes: Int64?, url: URL? = nil, lastUsed: Date? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.bytes = bytes
        self.url = url
        self.lastUsed = lastUsed
    }
}

/// Finds what hides in "System Data". Read-only: removal goes through the matching system tool.
public struct SystemDataInspector: Sendable {
    public let runner: CommandRunner
    public let home: URL
    /// Xcode's developer folder, for simctl; nil when Xcode isn't installed.
    public let developerDirectory: String?

    /// Where installers and Xcode copies are looked for.
    public let applicationFolder: URL
    public let systemRoot: URL

    public init(runner: CommandRunner = ProcessRunner(), home: URL, developerDirectory: String? = Self.findXcode(),
                applicationFolder: URL = URL(fileURLWithPath: "/Applications"), systemRoot: URL = URL(fileURLWithPath: "/")) {
        self.runner = runner
        self.home = home
        self.developerDirectory = developerDirectory
        self.applicationFolder = applicationFolder
        self.systemRoot = systemRoot
    }

    /// The full Xcode, not the Command Line Tools: only Xcode has simctl.
    public static func findXcode() -> String? {
        let candidates = ["/Applications/Xcode.app", "/Applications/Xcode-beta.app"]
        return candidates
            .map { $0 + "/Contents/Developer" }
            .first { FileManager.default.fileExists(atPath: $0 + "/usr/bin/simctl") }
    }

    public func inspect() async -> [SystemDataItem] {
        async let snapshots = localSnapshots()
        async let runtimes = simulatorRuntimes()
        async let unavailable = unavailableSimulators()
        let backups = deviceBackups()
        let messages = messagesAttachments()
        let found = macOSInstallers() + deviceFirmware() + extraXcodes() + soundLibraries() + [mailDownloads()].compactMap { $0 }
        return await [snapshots].compactMap { $0 } + runtimes + [unavailable].compactMap { $0 } + backups
            + found + [messages].compactMap { $0 }
    }

    // MARK: Time Machine

    func localSnapshots() async -> SystemDataItem? {
        let result = await runner.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        let dates = Self.snapshotDates(in: result.output)
        guard !dates.isEmpty else { return nil }
        return SystemDataItem(id: "snapshots", kind: .localSnapshots(dates: dates), title: "Time Machine", detail: nil, bytes: nil)
    }

    /// `com.apple.TimeMachine.2026-09-27-101500.local` → `2026-09-27-101500`, the form tmutil deletes by.
    static func snapshotDates(in output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let name = line.trimmingCharacters(in: .whitespaces)
            guard name.hasPrefix("com.apple.TimeMachine."), name.hasSuffix(".local") else { return nil }
            let date = String(name.dropFirst("com.apple.TimeMachine.".count).dropLast(".local".count))
            // These go to a command run as administrator: accept nothing but the expected shape.
            guard !date.isEmpty, date.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }) else { return nil }
            return date
        }
    }

    // MARK: Simulators

    private var simctlEnvironment: [String: String] {
        developerDirectory.map { ["DEVELOPER_DIR": $0] } ?? [:]
    }

    func simulatorRuntimes() async -> [SystemDataItem] {
        guard developerDirectory != nil else { return [] }
        let result = await runner.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], environment: simctlEnvironment)
        return Self.parseRuntimes(result.output)
    }

    static func parseRuntimes(_ json: String) -> [SystemDataItem] {
        guard let data = json.data(using: .utf8),
              let runtimes = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return [] }
        let dates = ISO8601DateFormatter()
        return runtimes.values.compactMap { runtime in
            guard let identifier = runtime["identifier"] as? String, runtime["deletable"] as? Bool != false else { return nil }
            let platform = (runtime["runtimeIdentifier"] as? String)?
                .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
                .split(separator: "-").first.map(String.init) ?? "Simulator"
            let version = runtime["version"] as? String ?? ""
            let build = runtime["build"] as? String
            let bytes = (runtime["sizeBytes"] as? NSNumber)?.int64Value
            return SystemDataItem(
                id: "runtime-" + identifier, kind: .simulatorRuntime(identifier: identifier),
                title: "\(platform) \(version)", detail: build, bytes: bytes,
                lastUsed: (runtime["lastUsedAt"] as? String).flatMap(dates.date(from:)))
        }
        .sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }

    func unavailableSimulators() async -> SystemDataItem? {
        guard developerDirectory != nil else { return nil }
        let result = await runner.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], environment: simctlEnvironment)
        return Self.parseUnavailable(result.output)
    }

    static func parseUnavailable(_ json: String) -> SystemDataItem? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = root["devices"] as? [String: [[String: Any]]]
        else { return nil }
        let unavailable = devices.values.flatMap { $0 }.filter { ($0["isAvailable"] as? Bool) == false }
        guard !unavailable.isEmpty else { return nil }
        let bytes = unavailable.reduce(Int64(0)) { $0 + ((($1["dataPathSize"] as? NSNumber)?.int64Value) ?? 0) }
        return SystemDataItem(id: "unavailable-simulators", kind: .unavailableSimulators(count: unavailable.count),
                              title: "Unavailable simulators", bytes: bytes)
    }

    // MARK: Files in the home folder

    /// Backups Finder made of iPhones and iPads, one folder per device.
    func deviceBackups() -> [SystemDataItem] {
        let root = home.appending(path: "Library/Application Support/MobileSync/Backup")
        return FileWalker.children(of: root, log: UnreadableLog()).compactMap { folder in
            let info = NSDictionary(contentsOf: folder.appending(path: "Info.plist"))
            let name = info?["Device Name"] as? String ?? info?["Display Name"] as? String ?? folder.lastPathComponent
            let date = info?["Last Backup Date"] as? Date
            let product = info?["Product Name"] as? String
            return SystemDataItem(
                id: "backup-" + folder.lastPathComponent, kind: .deviceBackup, title: name, detail: product,
                bytes: FileWalker.allocatedSize(of: folder, log: UnreadableLog()), url: folder, lastUsed: date)
        }
    }

    func messagesAttachments() -> SystemDataItem? {
        let folder = home.appending(path: "Library/Messages/Attachments")
        guard FileWalker.exists(folder) else { return nil }
        let bytes = FileWalker.allocatedSize(of: folder, log: UnreadableLog())
        // A few photos aren't worth a row.
        guard bytes >= 10_000_000 else { return nil }
        return SystemDataItem(id: "messages", kind: .messagesAttachments, title: "Messages attachments", bytes: bytes, url: folder)
    }

    // MARK: Forgotten downloads

    func macOSInstallers() -> [SystemDataItem] {
        FileWalker.children(of: applicationFolder, log: UnreadableLog())
            .filter { $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier?.hasPrefix("com.apple.InstallAssistant.") == true }
            .map { app in
                let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
                return SystemDataItem(id: "installer-" + app.path, kind: .macOSInstaller,
                                      title: app.deletingPathExtension().lastPathComponent, detail: version,
                                      bytes: FileWalker.allocatedSize(of: app, log: UnreadableLog()), url: app)
            }
    }

    /// `.ipsw` files in Finder's "iPhone Software Updates" and "iPad Software Updates" folders.
    func deviceFirmware() -> [SystemDataItem] {
        ["iPhone Software Updates", "iPad Software Updates", "iPod Software Updates"].flatMap { folder in
            FileWalker.children(of: home.appending(path: "Library/iTunes").appending(path: folder), log: UnreadableLog())
                .filter { $0.pathExtension.lowercased() == "ipsw" }
                .map { file in
                    SystemDataItem(id: "ipsw-" + file.path, kind: .deviceFirmware, title: file.deletingPathExtension().lastPathComponent,
                                   bytes: FileWalker.allocatedSize(of: file, log: UnreadableLog()), url: file,
                                   lastUsed: (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
                }
        }
    }

    /// Every Xcode except the one the developer tools point at.
    func extraXcodes() -> [SystemDataItem] {
        // Compare real paths: symlinks and /var → /private/var would otherwise hide the active copy.
        let active = developerDirectory.map {
            StorageAnalyzer.realURL(URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent()).path
        }
        let copies = FileWalker.children(of: applicationFolder, log: UnreadableLog())
            .filter { $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == "com.apple.dt.Xcode" }
        guard copies.count > 1 else { return [] }
        return copies.filter { StorageAnalyzer.realURL($0).path != active }.map { app in
            let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
            return SystemDataItem(id: "xcode-" + app.path, kind: .extraXcode, title: app.deletingPathExtension().lastPathComponent,
                                  detail: version, bytes: FileWalker.allocatedSize(of: app, log: UnreadableLog()), url: app)
        }
    }

    func soundLibraries() -> [SystemDataItem] {
        let folders = ["Library/Application Support/GarageBand", "Library/Application Support/Logic", "Library/Audio/Apple Loops"]
        let bytes = folders.map { systemRoot.appending(path: $0) }.filter(FileWalker.exists)
            .reduce(Int64(0)) { $0 + FileWalker.allocatedSize(of: $1, log: UnreadableLog()) }
        // Small installs come with every Mac; only a downloaded library is worth a row.
        guard bytes >= 500_000_000 else { return [] }
        return [SystemDataItem(id: "sound-library", kind: .soundLibrary, title: "GarageBand and Logic sounds", bytes: bytes,
                               url: systemRoot.appending(path: "Library/Application Support/GarageBand"))]
    }

    func mailDownloads() -> SystemDataItem? {
        let folder = home.appending(path: "Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        guard FileWalker.exists(folder) else { return nil }
        let bytes = FileWalker.allocatedSize(of: folder, log: UnreadableLog())
        guard bytes >= 50_000_000 else { return nil }
        return SystemDataItem(id: "mail-downloads", kind: .mailDownloads, title: "Mail attachments", bytes: bytes, url: folder)
    }

    // MARK: Removal

    /// Deletes a simulator runtime through simctl.
    public func deleteRuntime(_ identifier: String) async -> CommandResult {
        await runner.run("/usr/bin/xcrun", ["simctl", "runtime", "delete", identifier], environment: simctlEnvironment)
    }

    public func deleteUnavailableSimulators() async -> CommandResult {
        await runner.run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"], environment: simctlEnvironment)
    }

    /// The tmutil calls that delete these snapshots; they need an administrator.
    public static func snapshotDeletion(_ dates: [String]) -> [[String]] {
        dates.map { ["/usr/bin/tmutil", "deletelocalsnapshots", $0] }
    }
}
