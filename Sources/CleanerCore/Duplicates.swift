import CryptoKit
import Foundation

/// Files with byte-for-byte identical contents.
public struct DuplicateGroup: Identifiable, Sendable {
    public struct Copy: Identifiable, Hashable, Sendable {
        public let url: URL
        public let modified: Date?
        public var id: URL { url }
    }

    /// Size of one copy.
    public let bytes: Int64
    /// Oldest first: the original is usually the one to keep.
    public let copies: [Copy]

    public var id: URL { copies[0].url }

    public init(bytes: Int64, copies: [Copy]) {
        self.bytes = bytes
        self.copies = copies
    }
    /// What removing all but one copy would free.
    public var wastedBytes: Int64 { bytes * Int64(copies.count - 1) }
}

/// Finds identical files by size, then a hash of their first 64 KB, then a full SHA-256. Read-only.
public enum DuplicateFinder {
    public static let defaultMinimumSize: Int64 = 1_000_000

    /// - Parameter progress: files looked at so far, now and then.
    public static func find(
        in roots: [URL],
        minimumSize: Int64 = defaultMinimumSize,
        progress: (@Sendable (Int) -> Void)? = nil
    ) -> [DuplicateGroup] {
        var bySize: [Int64: [URL]] = [:]
        var seenFiles: Set<String> = []
        var count = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey,
                                      .fileSizeKey, .fileResourceIdentifierKey]

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                if Task.isCancelled { return [] }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true {
                    if url.lastPathComponent == "node_modules" { enumerator.skipDescendants() }
                    continue
                }
                guard values.isRegularFile == true, let size = values.fileSize, Int64(size) >= minimumSize else { continue }
                // Hard links are one file under two names, not a copy.
                if let identifier = values.fileResourceIdentifier.map({ "\($0)" }), !seenFiles.insert(identifier).inserted { continue }
                bySize[Int64(size), default: []].append(url)
                count += 1
                if count % 500 == 0 { progress?(count) }
            }
        }
        progress?(count)

        var groups: [DuplicateGroup] = []
        for (size, urls) in bySize where urls.count > 1 {
            if Task.isCancelled { return [] }
            // Cheap first: most same-size files already differ in their first 64 KB.
            let byHead = Dictionary(grouping: urls) { hash(of: $0, limit: 65_536) ?? UUID().uuidString }
            for candidates in byHead.values where candidates.count > 1 {
                let byContent = Dictionary(grouping: candidates) { hash(of: $0, limit: nil) ?? UUID().uuidString }
                for same in byContent.values where same.count > 1 {
                    let copies = same.map { url in
                        DuplicateGroup.Copy(url: url, modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
                    }
                    .sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
                    groups.append(DuplicateGroup(bytes: allocatedSize(same[0]) ?? size, copies: copies))
                }
            }
        }
        return groups.sorted { $0.wastedBytes > $1.wastedBytes }
    }

    /// SHA-256 of the whole file, or of its first `limit` bytes. nil if it can't be read.
    static func hash(of url: URL, limit: Int?) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? .max
        while remaining > 0 {
            let chunk = (try? handle.read(upToCount: min(1_048_576, remaining))) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func allocatedSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize.map(Int64.init)
    }

    /// Everything but the oldest copy of each group: the usual choice when cleaning up.
    public static func allButOldest(_ groups: [DuplicateGroup]) -> Set<URL> {
        Set(groups.flatMap { $0.copies.dropFirst().map(\.url) })
    }
}
