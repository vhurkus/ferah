import Foundation

/// A newer version of an installed app, and where it comes from.
public struct AppUpdate: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// The app's own Sparkle feed: the app installs it itself when opened.
        case sparkle
        /// The Mac App Store.
        case appStore(url: URL)
        /// Homebrew's catalog knows a newer version; `managed` when Homebrew installed this copy.
        case homebrew(token: String, homepage: URL?, managed: Bool)
    }

    public let appURL: URL
    public let installedVersion: String
    public let latestVersion: String
    public let source: Source

    public init(appURL: URL, installedVersion: String, latestVersion: String, source: Source) {
        self.appURL = appURL
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.source = source
    }
}

/// Version strings compared number by number: "2.10" is newer than "2.9", "1.2" equals "1.2.0".
public enum VersionNumber {
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = components(candidate), b = components(installed)
        guard !a.isEmpty, !b.isEmpty else { return false }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Leading numbers only: "154.0.8037.58" → [154, 0, 8037, 58]; "2.7.1 (123)" → [2, 7, 1];
    /// Homebrew's "26.4.1-57516,abc" → [26, 4, 1, 57516].
    static func components(_ version: String) -> [Int] {
        let head = version.split(separator: ",").first.map(String.init) ?? version
        let beforeSpace = head.split(separator: " ").first.map(String.init) ?? head
        return beforeSpace.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}

/// Asks each app's update channel for its newest version. Only runs when the user asks:
/// it tells the App Store, Homebrew and the apps' own servers which apps are installed.
public struct UpdateChecker: Sendable {
    public typealias Fetch = @Sendable (URL) async -> Data?

    public let fetch: Fetch
    /// Casks Homebrew installed on this Mac (their apps are updated through Homebrew).
    public let brewManagedTokens: Set<String>
    /// Where Homebrew's catalog is kept between checks; nil to always download it.
    public let catalogCache: URL?

    public init(brewManagedTokens: Set<String> = [], catalogCache: URL? = nil, fetch: @escaping Fetch = UpdateChecker.download) {
        self.brewManagedTokens = brewManagedTokens
        self.catalogCache = catalogCache
        self.fetch = fetch
    }

    /// The catalog changes a few times a day at most; a day-old copy is fine.
    static let catalogMaxAge: TimeInterval = 24 * 60 * 60

    public static let download: Fetch = { url in
        // The catalog is ~2 MB compressed and can be slow; everything else is small.
        var request = URLRequest(url: url, timeoutInterval: url.host == "formulae.brew.sh" ? 90 : 15)
        request.setValue("Ferah (+https://github.com/vhurkus/ferah)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    /// - Parameter progress: apps checked so far, and how many there are.
    public func check(_ apps: [InstalledApp], progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [URL: AppUpdate] {
        let apps = apps.filter { !$0.isAppleApp }
        // The catalog is the slow part: fetch it while apps with their own channel are checked.
        let catalog = Task { await homebrewCatalog() }
        progress?(0, apps.count)
        return await withTaskGroup(of: AppUpdate?.self) { group in
            for app in apps {
                group.addTask { await self.latest(for: app) { await catalog.value } }
            }
            var updates: [URL: AppUpdate] = [:]
            var done = 0
            for await update in group {
                done += 1
                progress?(done, apps.count)
                if let update { updates[update.appURL] = update }
            }
            return updates
        }
    }

    func latest(for app: InstalledApp, catalog: [String: CaskInfo]) async -> AppUpdate? {
        await latest(for: app) { catalog }
    }

    func latest(for app: InstalledApp, catalog: () async -> [String: CaskInfo]) async -> AppUpdate? {
        guard let installed = app.version else { return nil }
        if app.isFromAppStore, let id = app.bundleIdentifier,
           let found = await appStoreVersion(bundleIdentifier: id) {
            return VersionNumber.isNewer(found.version, than: installed)
                ? AppUpdate(appURL: app.url, installedVersion: installed, latestVersion: found.version, source: .appStore(url: found.url))
                : nil
        }
        if let feed = app.sparkleFeed, let data = await fetch(feed),
           let newest = Appcast.newest(in: data) {
            let comparable = newest.shortVersion ?? newest.version
            let installedComparable = newest.shortVersion != nil ? installed : (app.build ?? installed)
            return VersionNumber.isNewer(comparable, than: installedComparable)
                ? AppUpdate(appURL: app.url, installedVersion: installed, latestVersion: comparable, source: .sparkle)
                : nil
        }
        if let cask = await catalog()[app.url.lastPathComponent.lowercased()],
           VersionNumber.isNewer(cask.version, than: installed) {
            let shown = cask.version.split(separator: ",").first.map(String.init) ?? cask.version
            return AppUpdate(appURL: app.url, installedVersion: installed, latestVersion: shown,
                             source: .homebrew(token: cask.token, homepage: cask.homepage, managed: brewManagedTokens.contains(cask.token)))
        }
        return nil
    }

    // MARK: App Store

    func appStoreVersion(bundleIdentifier: String) async -> (version: String, url: URL)? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [.init(name: "bundleId", value: bundleIdentifier), .init(name: "entity", value: "desktopSoftware")]
        guard let url = components.url, let data = await fetch(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = (root["results"] as? [[String: Any]])?.first,
              let version = result["version"] as? String,
              let page = (result["trackViewUrl"] as? String).flatMap(URL.init(string:))
        else { return nil }
        return (version, page)
    }

    // MARK: Homebrew catalog

    struct CaskInfo: Sendable {
        let token: String
        let version: String
        let homepage: URL?
    }

    /// Homebrew's public cask catalog, keyed by the app bundle's file name ("google chrome.app").
    func homebrewCatalog() async -> [String: CaskInfo] {
        if let cache = catalogCache,
           let modified = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date.now.timeIntervalSince(modified) < Self.catalogMaxAge,
           let data = try? Data(contentsOf: cache) {
            let catalog = Self.parseCatalog(data)
            if !catalog.isEmpty { return catalog }
        }
        guard let url = URL(string: "https://formulae.brew.sh/api/cask.json"), let data = await fetch(url) else { return [:] }
        let catalog = Self.parseCatalog(data)
        if !catalog.isEmpty, let cache = catalogCache {
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cache, options: .atomic)
        }
        return catalog
    }

    static func parseCatalog(_ data: Data) -> [String: CaskInfo] {
        guard let casks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var byApp: [String: CaskInfo] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String, let version = cask["version"] as? String, version != "latest",
                  let artifacts = cask["artifacts"] as? [[String: Any]]
            else { continue }
            let homepage = (cask["homepage"] as? String).flatMap(URL.init(string:))
            for artifact in artifacts {
                guard let apps = artifact["app"] as? [Any] else { continue }
                for case let name as String in apps where name.hasSuffix(".app") {
                    let key = (name as NSString).lastPathComponent.lowercased()
                    // Several casks can ship an app of the same name (e.g. beta channels): keep the plain one.
                    if byApp[key] == nil || token.count < byApp[key]!.token.count {
                        byApp[key] = CaskInfo(token: token, version: version, homepage: homepage)
                    }
                }
            }
        }
        return byApp
    }
}

/// Reads a Sparkle appcast and picks its newest stable release.
enum Appcast {
    struct Release {
        let version: String
        let shortVersion: String?
    }

    static func newest(in data: Data) -> Release? {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        parser.parse()
        return delegate.releases
            .filter { !$0.isPrerelease }
            .compactMap { item in item.version.map { Release(version: $0, shortVersion: item.shortVersion) } }
            .max { a, b in VersionNumber.isNewer(b.shortVersion ?? b.version, than: a.shortVersion ?? a.version) }
    }

    private final class AppcastParser: NSObject, XMLParserDelegate {
        struct Item {
            var version: String?
            var shortVersion: String?
            var isPrerelease = false
        }

        var releases: [Item] = []
        private var current: Item?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            text = ""
            if name == "item" { current = Item() }
            if name == "enclosure" {
                if let version = attributes["sparkle:version"] { current?.version = version }
                if let short = attributes["sparkle:shortVersionString"] { current?.shortVersion = short }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "sparkle:version" where !value.isEmpty: current?.version = value
            case "sparkle:shortVersionString" where !value.isEmpty: current?.shortVersion = value
            // Beta channels aren't what "an update is available" should mean.
            case "sparkle:channel" where !value.isEmpty: current?.isPrerelease = true
            case "item":
                if let current { releases.append(current) }
                current = nil
            default: break
            }
            text = ""
        }
    }
}
