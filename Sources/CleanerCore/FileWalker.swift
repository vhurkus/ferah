import Foundation

/// Collects folders that exist but couldn't be read during one scan.
public final class UnreadableLog {
    public private(set) var urls: [URL] = []

    public init() {}

    func record(_ url: URL, _ error: Error) {
        if FileWalker.isPermissionError(error) { urls.append(url) }
    }
}

public enum FileWalker {
    static let sizeKeys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

    /// Allocated size of a file or folder tree. Doesn't follow symlinks; stops early on task cancellation.
    public static func allocatedSize(of url: URL, log: UnreadableLog) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: Set(sizeKeys)) else { return 0 }
        guard values.isDirectory == true else { return fileSize(values) }

        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: sizeKeys, options: [],
            errorHandler: { failedURL, error in
                log.record(failedURL, error)
                return true
            }
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            if Task.isCancelled { break }
            guard let childValues = try? child.resourceValues(forKeys: Set(sizeKeys)),
                  childValues.isDirectory != true
            else { continue }
            total += fileSize(childValues)
        }
        return total
    }

    /// Visible direct children of a folder; empty if it doesn't exist.
    static func children(of url: URL, log: UnreadableLog) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        } catch {
            log.record(url, error)
            return []
        }
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError { return true }
        let posix = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError) ?? nsError
        return posix.domain == NSPOSIXErrorDomain && (posix.code == Int(EPERM) || posix.code == Int(EACCES))
    }

    private static func fileSize(_ values: URLResourceValues) -> Int64 {
        Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}
