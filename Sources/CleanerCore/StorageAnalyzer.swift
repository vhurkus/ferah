import Foundation

/// One row of a folder's contents: a subfolder, a file, or the folder's small files taken together.
public struct StorageEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case folder
        case file
        /// Files below the map's minimum size, summed so small files don't flood the list.
        case smallFiles(count: Int)
    }

    public let url: URL
    public let bytes: Int64
    public let kind: Kind

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
    public var isFolder: Bool { kind == .folder }

    public init(url: URL, bytes: Int64, kind: Kind) {
        self.url = url
        self.bytes = bytes
        self.kind = kind
    }

    func with(bytes: Int64) -> StorageEntry { StorageEntry(url: url, bytes: bytes, kind: kind) }
}

/// Sizes of every folder under the measured roots, so any folder opens instantly.
/// Look folders up with URLs that come from the map (its roots and entries): those are resolved paths.
public struct StorageMap: Sendable {
    public let roots: [URL]
    /// Contents of each measured folder, largest first, keyed by path.
    private var contents: [String: [StorageEntry]]
    private var totals: [String: Int64]
    /// Folders that exist but couldn't be read (usually missing Full Disk Access).
    public let unreadable: [URL]

    init(roots: [URL], contents: [String: [StorageEntry]], totals: [String: Int64], unreadable: [URL]) {
        self.roots = roots
        self.contents = contents
        self.totals = totals
        self.unreadable = unreadable
    }

    /// Contents of a measured folder, largest first; nil if it wasn't measured.
    public func entries(in folder: URL) -> [StorageEntry]? { contents[folder.path] }

    /// Total size of a measured folder.
    public func size(of folder: URL) -> Int64? { totals[folder.path] }

    /// The map after `url` has been moved away: it disappears from its folder and every folder above
    /// it shrinks by its size, without measuring again.
    public func removing(_ url: URL) -> StorageMap {
        let parent = url.deletingLastPathComponent()
        // Compare paths, not URLs: folder URLs from the enumerator end in "/", others may not.
        guard let siblings = contents[parent.path], let entry = siblings.first(where: { $0.url.path == url.path }) else {
            return self
        }
        var map = self
        map.contents[parent.path] = siblings.filter { $0.url.path != url.path }
        let prefix = url.path + "/"
        for key in map.contents.keys where key == url.path || key.hasPrefix(prefix) {
            map.contents[key] = nil
            map.totals[key] = nil
        }

        // Shrink every measured folder from the parent up to its root.
        var folder = parent
        while let total = map.totals[folder.path] {
            map.totals[folder.path] = total - entry.bytes
            let above = folder.deletingLastPathComponent()
            guard !roots.contains(where: { $0.path == folder.path }), let aboveEntries = map.contents[above.path] else { break }
            map.contents[above.path] = aboveEntries
                .map { $0.url.path == folder.path ? $0.with(bytes: $0.bytes - entry.bytes) : $0 }
                .sorted { $0.bytes > $1.bytes }
            folder = above
        }
        return map
    }
}

/// Measures folder trees on disk. Read-only.
public enum StorageAnalyzer {
    /// Files smaller than this are summed per folder instead of listed one by one.
    public static let defaultMinimumFileSize: Int64 = 1_000_000

    /// Measures each root in one pass. Doesn't follow symlinks; stops early on task cancellation.
    /// `progress` gets the number of files measured so far, every few thousand files.
    public static func map(
        _ roots: [URL],
        minimumFileSize: Int64 = defaultMinimumFileSize,
        progress: (@Sendable (Int) -> Void)? = nil
    ) -> StorageMap {
        // The enumerator reports real paths (/var → /private/var), so key the roots the same way.
        // `resolvingSymlinksInPath()` won't do: it deliberately strips "/private".
        let roots = roots.map(realURL)
        let log = UnreadableLog()
        var contents: [String: [StorageEntry]] = [:]
        var totals: [String: Int64] = [:]
        var fileCount = 0

        for root in roots where FileWalker.exists(root) {
            measure(root, minimumFileSize: minimumFileSize, log: log, contents: &contents, totals: &totals) {
                fileCount += 1
                if fileCount % 5000 == 0 { progress?(fileCount) }
            }
            if Task.isCancelled { break }
        }
        progress?(fileCount)
        return StorageMap(roots: roots, contents: contents, totals: totals, unreadable: log.urls)
    }

    public static func realURL(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private struct Frame {
        let url: URL
        var entries: [StorageEntry] = []
        var total: Int64 = 0
        var smallBytes: Int64 = 0
        var smallCount = 0
    }

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    private static func measure(
        _ root: URL,
        minimumFileSize: Int64,
        log: UnreadableLog,
        contents: inout [String: [StorageEntry]],
        totals: inout [String: Int64],
        countFile: () -> Void
    ) {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [],
            errorHandler: { url, error in
                log.record(url, error)
                return true
            }
        ) else { return }

        var stack = [Frame(url: root)]

        // Closes the innermost open folder and adds it to the one around it.
        func finishTop() {
            let frame = stack.removeLast()
            var entries = frame.entries
            if frame.smallCount > 0 {
                entries.append(StorageEntry(
                    url: frame.url.appending(path: ".ferah-small-files"),
                    bytes: frame.smallBytes, kind: .smallFiles(count: frame.smallCount)))
            }
            contents[frame.url.path] = entries.sorted { $0.bytes > $1.bytes }
            totals[frame.url.path] = frame.total
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].total += frame.total
            stack[stack.count - 1].entries.append(StorageEntry(url: frame.url, bytes: frame.total, kind: .folder))
        }

        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            // `level` is 1 for the root's direct children: close folders we've left.
            while stack.count > enumerator.level { finishTop() }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }

            if values.isDirectory == true, values.isSymbolicLink != true {
                stack.append(Frame(url: url))
                continue
            }
            countFile()
            let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            stack[stack.count - 1].total += bytes
            if bytes >= minimumFileSize {
                stack[stack.count - 1].entries.append(StorageEntry(url: url, bytes: bytes, kind: .file))
            } else {
                stack[stack.count - 1].smallBytes += bytes
                stack[stack.count - 1].smallCount += 1
            }
        }
        while !stack.isEmpty { finishTop() }
    }
}
