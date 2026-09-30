import CryptoKit
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

@Suite struct UpdateInstallerTests {
    @Test func findsTheAppButNeverThroughSymlinks() throws {
        let home = try FakeHome()
        defer { home.remove() }
        try home.file("Image/Stats.app/Contents/Info.plist")
        try home.file("Elsewhere/Stats.app/Contents/Info.plist")
        try FileManager.default.createSymbolicLink(at: home.url.appending(path: "Image/Applications"),
                                                   withDestinationURL: home.url.appending(path: "Elsewhere"))
        let found = UpdateInstaller.findApp(in: home.url.appending(path: "Image"), preferring: "Stats.app")
        #expect(found?.path.contains("/Image/Stats.app") == true)

        try FileManager.default.removeItem(at: home.url.appending(path: "Image/Stats.app"))
        #expect(UpdateInstaller.findApp(in: home.url.appending(path: "Image"), preferring: "Stats.app") == nil)
    }

    @Test func readsTeamIdentifiers() {
        #expect(UpdateInstaller.teamIdentifier(inCodesignOutput: "Executable=/x\nTeamIdentifier=MN3X4648SC\n") == "MN3X4648SC")
        #expect(UpdateInstaller.teamIdentifier(inCodesignOutput: "TeamIdentifier=not set") == nil)
        #expect(UpdateInstaller.teamIdentifier(inCodesignOutput: "code object is not signed at all") == nil)
    }

    @Test func verifiesSparkleSignatures() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let archive = try home.file("update.zip", bytes: 5000)
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: Data(contentsOf: archive)).base64EncodedString()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

        #expect(UpdateInstaller.isValidEdSignature(signature, publicKey: publicKey, file: archive))
        #expect(!UpdateInstaller.isValidEdSignature(signature, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(), file: archive))
    }

    @Test func refusesAChecksumMismatchBeforeUnpacking() async throws {
        let home = try FakeHome()
        defer { home.remove() }
        let plist = try home.file("Apps/Stats.app/Contents/Info.plist")
        try (["CFBundleIdentifier": "eu.exelban.Stats", "CFBundleShortVersionString": "3.0"] as NSDictionary).write(to: plist)
        let archive = try home.file("download.zip", bytes: 1000)
        let installer = UpdateInstaller(runner: FakeRunner(codesign: "TeamIdentifier=ABCDE12345")) { _, _ in
            let copy = home.url.appending(path: "copy-\(UUID().uuidString).zip")
            try? FileManager.default.copyItem(at: archive, to: copy)
            return copy
        }
        let update = AppUpdate(appURL: home.url.appending(path: "Apps/Stats.app"), installedVersion: "3.0", latestVersion: "3.1",
                               source: .homebrew(token: "stats", homepage: nil, managed: false),
                               package: UpdatePackage(url: URL(string: "https://example.com/Stats.zip")!, sha256: String(repeating: "0", count: 64),
                                                      edSignature: nil, appFileName: "Stats.app"))
        await #expect(throws: UpdateInstaller.Failure.checksumMismatch) {
            _ = try await installer.prepare(update, installed: InstalledApp(url: update.appURL))
        }
    }
}

/// Answers codesign with a canned signature; everything else succeeds.
struct FakeRunner: CommandRunner {
    let codesign: String
    func run(_ executable: String, _ arguments: [String], environment: [String: String]) async -> CommandResult {
        executable.hasSuffix("codesign") && arguments.first == "-dv"
            ? CommandResult(status: 0, output: "", error: codesign)
            : CommandResult(status: 0, output: "", error: "")
    }
}
