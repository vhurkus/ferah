import Foundation
import Testing
@testable import CleanerCore

@Suite struct UpdateTests {
    @Test func comparesVersionsNumberByNumber() {
        #expect(VersionNumber.isNewer("2.10", than: "2.9"))
        #expect(!VersionNumber.isNewer("1.2", than: "1.2.0"))
        #expect(VersionNumber.isNewer("154.0.8037.58", than: "153.0.8010.37"))
        #expect(!VersionNumber.isNewer("2.7.1", than: "2.7.1 (123)"))
        #expect(VersionNumber.isNewer("26.4.2-57600,abc", than: "26.4.1-57516"))
        #expect(!VersionNumber.isNewer("latest", than: "1.0"))
    }

    @Test func picksTheNewestStableAppcastRelease() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
          <item><enclosure url="a" sparkle:version="210" sparkle:shortVersionString="2.1.0"/></item>
          <item><sparkle:version>230</sparkle:version><sparkle:shortVersionString>2.3.0</sparkle:shortVersionString>
                <enclosure url="c"/></item>
          <item><sparkle:channel>beta</sparkle:channel><enclosure url="b" sparkle:version="300" sparkle:shortVersionString="3.0b1"/></item>
        </channel></rss>
        """
        let newest = Appcast.newest(in: Data(xml.utf8))
        #expect(newest?.shortVersion == "2.3.0")
        #expect(newest?.version == "230")
    }

    @Test func mapsCatalogAppsToCasks() {
        let json = """
        [{"token": "google-chrome", "version": "154.0.8037.58", "homepage": "https://www.google.com/chrome/",
          "artifacts": [{"app": ["Google Chrome.app"]}, {"zap": []}]},
         {"token": "google-chrome@beta", "version": "155.0", "artifacts": [{"app": ["Google Chrome.app"]}]},
         {"token": "nightly", "version": "latest", "artifacts": [{"app": ["Nightly.app"]}]}]
        """
        let catalog = UpdateChecker.parseCatalog(Data(json.utf8))
        #expect(catalog["google chrome.app"]?.token == "google-chrome")
        #expect(catalog["nightly.app"] == nil)
    }

    @Test func checksEachSourceWithoutTheNetwork() async throws {
        let home = try FakeHome()
        defer { home.remove() }
        func app(_ name: String, _ info: [String: String], receipt: Bool = false) throws -> InstalledApp {
            let plist = try home.file("Apps/\(name).app/Contents/Info.plist")
            try (info as NSDictionary).write(to: plist)
            if receipt { try home.file("Apps/\(name).app/Contents/_MASReceipt/receipt") }
            return InstalledApp(url: home.url.appending(path: "Apps/\(name).app"))
        }
        let sparkle = try app("Maccy", ["CFBundleIdentifier": "org.p0deje.Maccy", "CFBundleShortVersionString": "2.7.1",
                                        "SUFeedURL": "https://example.com/appcast.xml"])
        let store = try app("AdBlock", ["CFBundleIdentifier": "com.example.adblock", "CFBundleShortVersionString": "3.0"], receipt: true)
        let catalogued = try app("Stats", ["CFBundleIdentifier": "eu.exelban.Stats", "CFBundleShortVersionString": "3.0.16"])
        let current = try app("Shottr", ["CFBundleIdentifier": "cc.ffitch.shottr", "CFBundleShortVersionString": "1.9"])

        let checker = UpdateChecker(brewManagedTokens: ["stats"]) { url in
            switch url.host {
            case "example.com": Data(#"<rss><channel><item><enclosure sparkle:version="280" sparkle:shortVersionString="2.8.0"/></item></channel></rss>"#.utf8)
            case "itunes.apple.com": Data(#"{"results": [{"version": "3.1", "trackViewUrl": "https://apps.apple.com/app/id1"}]}"#.utf8)
            case "formulae.brew.sh": Data(#"[{"token": "stats", "version": "3.1.0", "artifacts": [{"app": ["Stats.app"]}]}, {"token": "shottr", "version": "1.9", "artifacts": [{"app": ["Shottr.app"]}]}]"#.utf8)
            default: nil
            }
        }
        let updates = await checker.check([sparkle, store, catalogued, current])

        #expect(updates[sparkle.url]?.latestVersion == "2.8.0")
        #expect(updates[sparkle.url]?.source == .sparkle)
        #expect(updates[store.url]?.latestVersion == "3.1")
        #expect(updates[catalogued.url]?.source == .homebrew(token: "stats", homepage: nil, managed: true))
        #expect(updates[current.url] == nil)
    }

    @Test func reusesAFreshCatalogFromDisk() async throws {
        let home = try FakeHome()
        defer { home.remove() }
        let cache = home.url.appending(path: "Caches/casks.json")
        let json = #"[{"token": "stats", "version": "9.0", "artifacts": [{"app": ["Stats.app"]}]}]"#
        let downloads = Counter()
        let checker = UpdateChecker(catalogCache: cache) { _ in
            downloads.increment()
            return Data(json.utf8)
        }
        let first = await checker.homebrewCatalog()
        let second = await checker.homebrewCatalog()

        #expect(first["stats.app"]?.version == "9.0")
        #expect(second["stats.app"]?.version == "9.0")
        #expect(downloads.value == 1)
    }
}

final class Counter: @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
