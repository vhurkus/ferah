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

    public init(runner: CommandRunner = ProcessRunner(), home: URL, developerDirectory: String? = Self.findXcode()) {
        self.runner = runner
        self.home = home
        self.developerDirectory = developerDirectory
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
        return await [snapshots].compactMap { $0 } + runtimes + [unavailable].compactMap { $0 } + backups + [messages].compactMap { $0 }
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
