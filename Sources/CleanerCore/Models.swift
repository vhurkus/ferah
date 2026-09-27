import Foundation

/// Why an item may be removed. Shown next to every item, always as icon + text.
public enum SafetyLabel: String, CaseIterable, Sendable {
    /// The owning app or tool recreates it on demand (caches, build products).
    case regenerates
    /// Nothing depends on it (old logs).
    case safe
    /// Data that provably belongs to an app being uninstalled (named after its bundle identifier).
    case appData
    /// Only the user can decide (their own files, archives, guesses by name).
    case review
}

public enum ModuleKind: String, CaseIterable, Identifiable, Sendable {
    case caches, developer, largeFiles, apps

    public var id: String { rawValue }

    /// Labels this module can produce, shown before a scan has results.
    public var expectedLabels: [SafetyLabel] {
        switch self {
        case .caches: [.regenerates, .safe]
        case .developer: [.regenerates, .review]
        case .largeFiles, .apps: [.review]
        }
    }

    /// Apps aren't sized on the overview: what gets removed is the user's choice.
    public var isSized: Bool { self != .apps }
}

public struct ScanItem: Identifiable, Hashable, Sendable {
    public let url: URL
    /// Allocated bytes on disk; 0 when the module doesn't measure size.
    public let bytes: Int64
    public let safety: SafetyLabel
    /// Last content change; only filled where it matters (large & old files).
    public let modified: Date?
    /// When an app was last opened, from Spotlight; only filled for apps.
    public let lastUsed: Date?

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public init(url: URL, bytes: Int64, safety: SafetyLabel, modified: Date? = nil, lastUsed: Date? = nil) {
        self.url = url
        self.bytes = bytes
        self.safety = safety
        self.modified = modified
        self.lastUsed = lastUsed
    }
}

public struct ModuleResult: Sendable {
    public var items: [ScanItem]
    /// Folders that exist but couldn't be read (usually missing Full Disk Access).
    public var unreadable: [URL]

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    /// Bytes that can go without a second thought (rebuilt automatically or safe).
    public var safeBytes: Int64 { items.filter { $0.safety != .review }.reduce(0) { $0 + $1.bytes } }
    public var reviewBytes: Int64 { totalBytes - safeBytes }

    /// Labels present in the results, in a fixed order.
    public var labels: [SafetyLabel] {
        SafetyLabel.allCases.filter { label in items.contains { $0.safety == label } }
    }

    public func count(of label: SafetyLabel) -> Int { items.filter { $0.safety == label }.count }

    public func removing(_ urls: Set<URL>) -> ModuleResult {
        ModuleResult(items: items.filter { !urls.contains($0.url) }, unreadable: unreadable)
    }

    public init(items: [ScanItem], unreadable: [URL]) {
        self.items = items
        self.unreadable = unreadable
    }
}

public struct VolumeInfo: Equatable, Sendable {
    public let name: String
    public let totalBytes: Int64
    public let availableBytes: Int64

    public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

    public init(name: String, totalBytes: Int64, availableBytes: Int64) {
        self.name = name
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    public static func current(for url: URL = URL(fileURLWithPath: "/")) throws -> VolumeInfo {
        let values = try url.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { throw CocoaError(.fileReadUnknown) }
        return VolumeInfo(name: values.volumeName ?? "", totalBytes: Int64(total), availableBytes: available)
    }
}
