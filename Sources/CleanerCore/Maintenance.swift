import Foundation

/// Small repairs macOS has tools for but no buttons: stale "Open With" entries, DNS, Spotlight, thumbnails.
public enum Maintenance {
    public static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

    /// Apps Launch Services still knows about that are gone or in the Trash: they cause duplicate
    /// "Open With" entries and ghost results. Never anything under /System.
    public static func staleRegistrations(runner: CommandRunner = ProcessRunner(),
                                          exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) async -> [String] {
        let dump = await runner.run(lsregister, ["-dump"])
        return staleRegistrations(in: dump.output, exists: exists)
    }

    static func staleRegistrations(in dump: String, exists: (String) -> Bool) -> [String] {
        var paths: Set<String> = []
        for line in dump.split(separator: "\n") where line.hasPrefix("path:") {
            // path:   /Applications/Foo.app (0x1a2b)
            var value = line.dropFirst("path:".count).trimmingCharacters(in: .whitespaces)
            if let range = value.range(of: #" \(0x[0-9a-f]+\)$"#, options: .regularExpression) { value.removeSubrange(range) }
            guard value.hasSuffix(".app"), value.hasPrefix("/"), !value.hasPrefix("/System/") else { continue }
            // Apps on a disk that isn't mounted: macOS keeps those until the disk returns and already
            // leaves them out of Open With, and unregistering can't remove them.
            if value.hasPrefix("/Volumes/") {
                let volume = value.split(separator: "/").prefix(2).joined(separator: "/")
                if !exists("/" + volume) { continue }
            }
            if value.contains("/.Trash/") || !exists(value) { paths.insert(value) }
        }
        return paths.sorted()
    }

    /// Unregisters the given apps (in batches, to keep command lines short), then compacts the database.
    public static func unregister(_ paths: [String], runner: CommandRunner = ProcessRunner()) async -> CommandResult {
        var last = CommandResult(status: 0, output: "", error: "")
        for start in stride(from: 0, to: paths.count, by: 50) {
            let batch = Array(paths[start..<min(start + 50, paths.count)])
            last = await runner.run(lsregister, ["-u"] + batch)
        }
        let compacted = await runner.run(lsregister, ["-gc"])
        return last.succeeded ? compacted : last
    }

    /// Needs an administrator.
    public static let flushDNS: [[String]] = [
        ["/usr/bin/dscacheutil", "-flushcache"],
        ["/usr/bin/killall", "-HUP", "mDNSResponder"],
    ]

    /// Erases and rebuilds the startup disk's Spotlight index. Needs an administrator.
    public static let rebuildSpotlight: [[String]] = [["/usr/bin/mdutil", "-E", "/"]]

    public static let resetThumbnails = ["/usr/bin/qlmanage", "-r", "cache"]
}
