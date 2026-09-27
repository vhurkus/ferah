import Foundation
import Testing
@testable import CleanerCore

/// A throwaway home folder so tests never touch the real one.
struct FakeHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "CleanerCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ path: String, bytes: Int = 4096, modified: Date? = nil) throws -> URL {
        let fileURL = url.appending(path: path)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: fileURL)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: fileURL.path)
        }
        return fileURL
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

@Suite struct ScannerTests {
    @Test func cachesAndLogsAreLabelledAndDeveloperCachesExcluded() throws {
        let home = try FakeHome()
        defer { home.remove() }
        try home.file("Library/Caches/com.example.app/blob")
        try home.file("Library/Caches/Homebrew/downloads/pkg")
        try home.file("Library/Logs/Example/old.log")

        let result = Scanner.scan(.caches, home: home.url)
        let names = Dictionary(uniqueKeysWithValues: result.items.map { ($0.url.lastPathComponent, $0.safety) })

        #expect(names == ["com.example.app": .regenerates, "Example": .safe])
        #expect(result.totalBytes > 0)
    }

    @Test func developerFindsKnownPathsAndTopLevelNodeModulesOnly() throws {
        let home = try FakeHome()
        defer { home.remove() }
        try home.file("Library/Developer/Xcode/DerivedData/App-abc/Build/x.o")
        try home.file("Library/Developer/Xcode/Archives/2026-09-01/App.xcarchive/Info.plist")
        try home.file("Library/Caches/Homebrew/downloads/pkg")
        try home.file("Desktop/site/node_modules/react/index.js")
        try home.file("Desktop/site/node_modules/react/node_modules/dep/index.js")

        let result = Scanner.scan(.developer, home: home.url)
        // The temp folder lives behind the /var → /private/var symlink.
        let homePath = home.url.resolvingSymlinksInPath().path + "/"
        let byPath = Dictionary(uniqueKeysWithValues: result.items.map {
            ($0.url.resolvingSymlinksInPath().path.replacingOccurrences(of: homePath, with: ""), $0.safety)
        })

        #expect(byPath["Library/Developer/Xcode/DerivedData"] == .regenerates)
        #expect(byPath["Library/Developer/Xcode/Archives"] == .review)
        #expect(byPath["Library/Caches/Homebrew"] == .regenerates)
        #expect(byPath["Desktop/site/node_modules"] == .regenerates)
        #expect(result.items.filter { $0.url.lastPathComponent == "node_modules" }.count == 1)
    }

    @Test func largeFilesAndOldDownloadsNeedReview() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let now = Date()
        var rules = ScanRules()
        rules.largeFileThreshold = 64 * 1024
        rules.oldDownloadMinimum = 1024

        try home.file("Movies/big.mov", bytes: 128 * 1024)
        try home.file("Documents/small.txt")
        try home.file("Downloads/old.dmg", bytes: 8192, modified: now.addingTimeInterval(-200 * 86_400))
        try home.file("Downloads/new.dmg", bytes: 8192, modified: now)
        try home.file("Desktop/p/node_modules/huge.bin", bytes: 128 * 1024)

        let result = Scanner.scan(.largeFiles, home: home.url, rules: rules, now: now)
        let names = Set(result.items.map(\.url.lastPathComponent))

        #expect(names == ["big.mov", "old.dmg"])
        #expect(result.items.allSatisfy { $0.safety == .review })
    }

    @Test func appsExcludeAppleBundlesAndAreSized() throws {
        let home = try FakeHome()
        defer { home.remove() }
        for (name, id) in [("Thing", "com.example.thing"), ("Safari", "com.apple.Safari")] {
            let plist = try home.file("Apps/\(name).app/Contents/Info.plist")
            try (["CFBundleIdentifier": id] as NSDictionary).write(to: plist)
        }

        let result = Scanner.scan(.apps, home: home.url, applicationRoots: [home.url.appending(path: "Apps")])

        #expect(result.items.map(\.url.lastPathComponent) == ["Thing.app"])
        #expect(result.totalBytes > 0)
    }

    @Test func appsAreFoundOneFolderDownButNotInsideBundles() throws {
        let home = try FakeHome()
        defer { home.remove() }
        for path in ["Apps/Suite/Tool.app", "Apps/Host.app/Contents/Helper.app", "Apps/Host.app"] {
            let plist = try home.file("\(path)/Contents/Info.plist")
            try (["CFBundleIdentifier": "com.example.\(UUID().uuidString)"] as NSDictionary).write(to: plist)
        }

        let result = Scanner.scan(.apps, home: home.url, applicationRoots: [home.url.appending(path: "Apps")])

        #expect(Set(result.items.map(\.url.lastPathComponent)) == ["Tool.app", "Host.app"])
    }

    @Test func missingFoldersProduceEmptyResultsWithoutUnreadableNoise() throws {
        let home = try FakeHome()
        defer { home.remove() }
        for module in ModuleKind.allCases where module.isSized {
            let result = Scanner.scan(module, home: home.url)
            #expect(result.items.isEmpty)
            #expect(result.unreadable.isEmpty)
        }
    }

    @Test func unreadableFolderIsReported() throws {
        let home = try FakeHome()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.url.appending(path: "Library/Logs").path)
            home.remove()
        }
        try home.file("Library/Logs/x.log")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: home.url.appending(path: "Library/Logs").path)

        let result = Scanner.scan(.caches, home: home.url)

        #expect(result.unreadable.map(\.lastPathComponent) == ["Logs"])
    }
}

@Suite struct LargeFileRuleTests {
    @Test func searchesEveryHomeFolderButLibraryAndApplications() throws {
        let home = try FakeHome()
        defer { home.remove() }
        var rules = ScanRules()
        rules.largeFileThreshold = 64 * 1024
        try home.file("RiderProjects/app/big.bin", bytes: 128 * 1024)
        try home.file("Library/Caches/x/big.bin", bytes: 128 * 1024)
        try home.file("Applications/Thing.app/Contents/big.bin", bytes: 128 * 1024)
        try home.file(".hidden/big.bin", bytes: 128 * 1024)

        let result = Scanner.scan(.largeFiles, home: home.url, rules: rules)

        #expect(result.items.map { $0.url.deletingLastPathComponent().lastPathComponent } == ["app"])
    }

    @Test func oldDownloadRuleCanBeTurnedOff() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let now = Date()
        var rules = ScanRules()
        rules.oldDownloadMinimum = 1024
        rules.oldDownloadAge = nil
        try home.file("Downloads/old.dmg", bytes: 8192, modified: now.addingTimeInterval(-400 * 86_400))

        #expect(Scanner.scan(.largeFiles, home: home.url, rules: rules, now: now).items.isEmpty)
    }
}

@Suite struct OrphanFinderTests {
    @Test func readsIdentifiersFromLibraryNames() {
        #expect(OrphanFinder.identifier(in: "com.example.Thing") == "com.example.Thing")
        #expect(OrphanFinder.identifier(in: "com.example.thing.plist") == "com.example.thing")
        #expect(OrphanFinder.identifier(in: "com.example.thing.savedState") == "com.example.thing")
        #expect(OrphanFinder.identifier(in: "group.com.example.thing") == "com.example.thing")
        #expect(OrphanFinder.identifier(in: "ABCDE12345.com.example.thing") == "com.example.thing")
        #expect(OrphanFinder.identifier(in: "Ferah Test") == nil)
        #expect(OrphanFinder.identifier(in: "Google") == nil)
        #expect(OrphanFinder.identifier(in: "com.example") == nil)
        #expect(OrphanFinder.identifier(in: "foo.bar.baz") == nil)
    }

    @Test func findsOnlyItemsOfAppsThatAreGone() throws {
        let home = try FakeHome()
        defer { home.remove() }
        try home.file("Library/Application Support/com.gone.app/db")
        try home.file("Library/Preferences/com.gone.app.plist")
        try home.file("Library/Caches/com.installed.app/x")
        try home.file("Library/Containers/com.installed.app.ShareExtension/x")
        try home.file("Library/Caches/com.elsewhere.app/x")
        try home.file("Library/Preferences/com.apple.finder.plist")
        try home.file("Library/Application Support/Some Folder/x")
        try home.file("Library/Caches/org.swift.swiftpm/x")

        let result = OrphanFinder.find(
            home: home.url,
            installedIdentifiers: ["com.installed.app"],
            isInstalled: { $0 == "com.elsewhere.app" }
        )

        #expect(Set(result.items.map(\.name)) == ["com.gone.app", "com.gone.app.plist"])
        #expect(result.items.allSatisfy { $0.safety == .review })
    }
}
