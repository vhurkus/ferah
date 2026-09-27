import Foundation

/// An app the user moved to the Trash themselves, with what it left behind.
public struct TrashedApp: Identifiable, Sendable {
    public let app: InstalledApp
    /// Leftovers only; the app bundle is already in the Trash.
    public let leftovers: ModuleResult

    public var id: URL { app.url }

    public init(app: InstalledApp, leftovers: ModuleResult) {
        self.app = app
        self.leftovers = leftovers
    }
}

public enum TrashedAppFinder {
    /// App bundles directly in the Trash (Finder puts dragged apps there, renaming on clashes).
    public static func appsInTrash(_ trash: URL) -> [URL] {
        FileWalker.children(of: trash, log: UnreadableLog()).filter { $0.pathExtension == "app" }
    }

    /// The leftovers of an app that's in the Trash, or nil when there's nothing worth mentioning.
    public static func leftovers(of appURL: URL, home: URL, systemRoot: URL = URL(fileURLWithPath: "/")) -> TrashedApp? {
        let app = InstalledApp(url: appURL)
        guard app.bundleIdentifier != nil, !app.isAppleApp else { return nil }
        let found = LeftoverFinder.find(for: app, home: home, systemRoot: systemRoot)
        let leftovers = found.removing([appURL])
        guard !leftovers.items.isEmpty else { return nil }
        return TrashedApp(app: app, leftovers: leftovers)
    }
}
