import CoreServices
import Foundation

public struct ScanRules: Sendable {
    public var largeFileThreshold: Int64 = 500_000_000
    /// Downloads untouched for this long count as old; nil turns the rule off.
    public var oldDownloadAge: TimeInterval? = 180 * 24 * 60 * 60
    /// Old downloads smaller than this aren't worth listing.
    public var oldDownloadMinimum: Int64 = 1_000_000
    public var projectSearchDepth = 6

    public init() {}
}

/// Finds removable items. Read-only: nothing here moves or deletes files.
public enum Scanner {
    /// Cache folders under ~/Library/Caches that belong to the developer module instead.
    static let developerCacheNames: Set<String> = ["Homebrew", "pip", "Yarn", "CocoaPods"]

    static let developerPaths: [(path: String, safety: SafetyLabel)] = [
        ("Library/Developer/Xcode/DerivedData", .regenerates),
        ("Library/Developer/Xcode/iOS DeviceSupport", .regenerates),
        ("Library/Developer/CoreSimulator/Caches", .regenerates),
        ("Library/Developer/Xcode/Archives", .review),
        ("Library/Caches/Homebrew", .regenerates),
        ("Library/Caches/pip", .regenerates),
        ("Library/Caches/Yarn", .regenerates),
        (".cache/pip", .regenerates),
        (".npm/_cacache", .regenerates),
        (".gradle/caches", .regenerates),
        (".gradle/wrapper/dists", .regenerates),
        ("Library/Caches/CocoaPods", .regenerates),
        (".nuget/packages", .regenerates),
        (".cargo/registry", .regenerates),
        ("go/pkg/mod", .regenerates),
        (".pub-cache", .regenerates),
        (".bun/install/cache", .regenerates),
        ("Library/pnpm/store", .regenerates),
        // Simulator devices hold installed test apps and their data.
        ("Library/Developer/CoreSimulator/Devices", .review),
        // Holds Docker images and containers: only the user knows if they're disposable.
        ("Library/Containers/com.docker.docker/Data/vms", .review),
    ]

    /// Home folders searched for node_modules.
    static let projectRoots = ["Desktop", "Documents", "Developer", "Projects", "Code", "src"]

    /// Home folders that hold settings and apps rather than the user's own files.
    static let largeFileExcludedRoots: Set<String> = ["Library", "Applications"]

    /// Every visible folder in the home folder except Library and Applications.
    public static func largeFileRoots(home: URL, log: UnreadableLog = UnreadableLog()) -> [URL] {
        FileWalker.children(of: home, log: log).filter { url in
            guard !largeFileExcludedRoots.contains(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
            else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true && values.isPackage != true
        }
    }

    public static func defaultApplicationRoots(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appending(path: "Applications")]
    }

    public static func scan(
        _ module: ModuleKind,
        home: URL,
        applicationRoots: [URL]? = nil,
        rules: ScanRules = .init(),
        now: Date = .now
    ) -> ModuleResult {
        let log = UnreadableLog()
        let items: [ScanItem] = switch module {
        case .caches: caches(home: home, log: log)
        case .developer: developer(home: home, rules: rules, log: log)
        case .largeFiles: largeFiles(home: home, rules: rules, now: now, log: log)
        case .apps: apps(roots: applicationRoots ?? defaultApplicationRoots(home: home), log: log)
        }
        let kept = module.isSized ? items.filter { $0.bytes > 0 } : items
        return ModuleResult(items: kept.sorted { $0.bytes > $1.bytes }, unreadable: log.urls)
    }

    static func caches(home: URL, log: UnreadableLog) -> [ScanItem] {
        let library = home.appending(path: "Library")
        let caches = FileWalker.children(of: library.appending(path: "Caches"), log: log)
            .filter { !developerCacheNames.contains($0.lastPathComponent) }
            .map { ScanItem(url: $0, bytes: FileWalker.allocatedSize(of: $0, log: log), safety: .regenerates) }
        let logs = FileWalker.children(of: library.appending(path: "Logs"), log: log)
            .map { ScanItem(url: $0, bytes: FileWalker.allocatedSize(of: $0, log: log), safety: .safe) }
        return caches + logs
    }

    static func developer(home: URL, rules: ScanRules, log: UnreadableLog) -> [ScanItem] {
        let known = developerPaths
            .map { (url: home.appending(path: $0.path), safety: $0.safety) }
            .filter { FileWalker.exists($0.url) }
            .map { ScanItem(url: $0.url, bytes: FileWalker.allocatedSize(of: $0.url, log: log), safety: $0.safety) }
        let nodeModules = projectRoots
            .map { home.appending(path: $0) }
            .filter { FileWalker.exists($0) }
            .flatMap { findNodeModules(in: $0, depth: rules.projectSearchDepth, log: log) }
            .map { ScanItem(url: $0, bytes: FileWalker.allocatedSize(of: $0, log: log), safety: .regenerates) }
        return known + nodeModules
    }

    /// Top-level node_modules folders only; never descends into one.
    static func findNodeModules(in root: URL, depth: Int, log: UnreadableLog) -> [URL] {
        guard depth > 0, !Task.isCancelled else { return [] }
        var found: [URL] = []
        for child in FileWalker.children(of: root, log: log) {
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isPackage != true, values.isSymbolicLink != true
            else { continue }
            if child.lastPathComponent == "node_modules" {
                found.append(child)
            } else {
                found += findNodeModules(in: child, depth: depth - 1, log: log)
            }
        }
        return found
    }

    static func largeFiles(home: URL, rules: ScanRules, now: Date, log: UnreadableLog) -> [ScanItem] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey,
                                      .fileAllocatedSizeKey, .contentModificationDateKey]
        let oldCutoff = rules.oldDownloadAge.map { now.addingTimeInterval(-$0) }
        var items: [ScanItem] = []

        for root in largeFileRoots(home: home, log: log) {
            let isDownloads = root.lastPathComponent == "Downloads"
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    log.record(url, error)
                    return true
                }
            ) else { continue }

            for case let url as URL in enumerator {
                if Task.isCancelled { return items }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true {
                    // Covered by the developer module.
                    if url.lastPathComponent == "node_modules" { enumerator.skipDescendants() }
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                let isLarge = bytes >= rules.largeFileThreshold
                let isOldDownload = isDownloads && bytes >= rules.oldDownloadMinimum
                    && oldCutoff.map { (values.contentModificationDate ?? now) < $0 } == true
                if isLarge || isOldDownload {
                    items.append(ScanItem(url: url, bytes: bytes, safety: .review, modified: values.contentModificationDate))
                }
            }
        }
        return items
    }

    /// Third-party apps only: Apple's own apps are protected by the system and can't be removed.
    /// Also looks one plain folder down, where suites install (e.g. /Applications/Adobe Photoshop 2025/).
    static func apps(roots: [URL], log: UnreadableLog) -> [ScanItem] {
        roots.flatMap { root in
            FileWalker.children(of: root, log: log).flatMap { child -> [URL] in
                if child.pathExtension == "app" { return [child] }
                guard child.pathExtension.isEmpty,
                      (try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
                          .map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true
                else { return [] }
                return FileWalker.children(of: child, log: log).filter { $0.pathExtension == "app" }
            }
        }
        .filter { !TrashPolicy.isAppleBundle($0) }
        .map { ScanItem(url: $0, bytes: AppSizeCache.shared.size(of: $0, log: log), safety: .review, lastUsed: lastUsed($0)) }
    }

    /// When the app was last opened, as Spotlight records it; nil if never opened or not indexed.
    static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

/// App bundle sizes, remembered until the bundle changes, so rescans don't re-measure Xcode every time.
final class AppSizeCache: @unchecked Sendable {
    static let shared = AppSizeCache()

    private var sizes: [URL: (modified: Date, bytes: Int64)] = [:]
    private let lock = NSLock()

    func size(of url: URL, log: UnreadableLog) -> Int64 {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let cached = lock.withLock({ sizes[url] }), cached.modified == modified { return cached.bytes }
        let bytes = FileWalker.allocatedSize(of: url, log: log)
        lock.withLock { sizes[url] = (modified, bytes) }
        return bytes
    }
}
