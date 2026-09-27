import Foundation
import Testing
@testable import CleanerCore

@Suite struct TrashPolicyTests {
    @Test func allowsItemsInsideHomeFolders() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let cache = try home.file("Library/Caches/com.example.app/blob").deletingLastPathComponent()
        let download = try home.file("Downloads/old.dmg")
        let nodeModules = try home.file("Desktop/site/node_modules/x.js").deletingLastPathComponent()

        for url in [cache, download, nodeModules] {
            #expect(TrashPolicy.check(url, home: home.url, applicationRoots: []) == nil)
        }
    }

    @Test func protectsHomeAndLibraryTopLevelFolders() throws {
        let home = try FakeHome()
        defer { home.remove() }
        try home.file("Library/Caches/x/blob")
        try home.file("Desktop/a.txt")

        for path in ["Library", "Library/Caches", "Desktop"] {
            #expect(TrashPolicy.check(home.url.appending(path: path), home: home.url, applicationRoots: []) == .protectedLocation)
        }
        #expect(TrashPolicy.check(home.url, home: home.url, applicationRoots: []) == .outsideAllowedLocations)
    }

    @Test func rejectsPathsOutsideHome() throws {
        let home = try FakeHome()
        defer { home.remove() }
        #expect(TrashPolicy.check(URL(fileURLWithPath: "/System/Library"), home: home.url, applicationRoots: []) == .outsideAllowedLocations)
        #expect(TrashPolicy.check(URL(fileURLWithPath: "/does/not/exist"), home: home.url, applicationRoots: []) == .missing)
    }

    @Test func rejectsSymlinkThatEscapesHome() throws {
        let home = try FakeHome()
        defer { home.remove() }
        try home.file("Library/Caches/placeholder")
        let link = home.url.appending(path: "Library/Caches/escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/usr/bin"))

        #expect(TrashPolicy.check(link, home: home.url, applicationRoots: []) == .outsideAllowedLocations)
    }

    @Test func allowsThirdPartyAppsButNotAppleApps() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let apps = home.url.appending(path: "Apps")
        for (name, id) in [("Thing", "com.example.thing"), ("Safari", "com.apple.Safari")] {
            let plist = try home.file("Apps/\(name).app/Contents/Info.plist")
            try (["CFBundleIdentifier": id] as NSDictionary).write(to: plist)
        }

        #expect(TrashPolicy.check(apps.appending(path: "Thing.app"), home: home.url, applicationRoots: [apps]) == nil)
        #expect(TrashPolicy.check(apps.appending(path: "Safari.app"), home: home.url, applicationRoots: [apps]) == .systemApp)
    }

    @Test func allowsAppsOneFolderDownButNotNestedHelperApps() throws {
        let base = try FakeHome()
        defer { base.remove() }
        let home = base.url.appending(path: "Home")
        try base.file("Home/.keep")
        let apps = base.url.appending(path: "Apps")
        for path in ["Apps/Suite/Tool.app", "Apps/Host.app/Helper.app", "Apps/A/B/Deep.app"] {
            let plist = try base.file("\(path)/Contents/Info.plist")
            try (["CFBundleIdentifier": "com.example.\(UUID().uuidString)"] as NSDictionary).write(to: plist)
        }

        #expect(TrashPolicy.check(apps.appending(path: "Suite/Tool.app"), home: home, applicationRoots: [apps]) == nil)
        #expect(TrashPolicy.check(apps.appending(path: "Host.app/Helper.app"), home: home, applicationRoots: [apps]) == .outsideAllowedLocations)
        #expect(TrashPolicy.check(apps.appending(path: "A/B/Deep.app"), home: home, applicationRoots: [apps]) == .outsideAllowedLocations)
    }

    @Test func rejectsAppleAppsAnywhere() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let plist = try home.file("Downloads/Safari.app/Contents/Info.plist")
        try (["CFBundleIdentifier": "com.apple.Safari"] as NSDictionary).write(to: plist)

        #expect(TrashPolicy.check(home.url.appending(path: "Downloads/Safari.app"), home: home.url, applicationRoots: []) == .systemApp)
    }

    @Test func protectsSensitiveLibraryFolders() throws {
        let home = try FakeHome()
        defer { home.remove() }
        for path in ["Library/Keychains/login.keychain-db", "Library/Mobile Documents/com~apple~CloudDocs/a.txt",
                     "Library/CloudStorage/Dropbox/a.txt", "Library/Mail/V10/x"] {
            let url = try home.file(path)
            #expect(TrashPolicy.check(url, home: home.url, applicationRoots: []) == .protectedLocation, "\(path)")
        }
    }

    @Test func allowsDirectSystemLeftoversOnly() throws {
        let base = try FakeHome()
        defer { base.remove() }
        let home = base.url.appending(path: "Home")
        let system = base.url.appending(path: "System")
        try base.file("Home/.keep")
        let daemon = try base.file("System/Library/LaunchDaemons/com.example.thing.plist")
        let appleDaemon = try base.file("System/Library/LaunchDaemons/com.apple.thing.plist")
        let deep = try base.file("System/Library/Application Support/Thing/data/x")
        let other = try base.file("System/Library/Extensions/Thing.kext")
        let check = { (url: URL) in TrashPolicy.check(url, home: home, applicationRoots: [], systemRoot: system) }

        #expect(check(daemon) == nil)
        #expect(check(appleDaemon) == .systemData)
        #expect(check(deep.deletingLastPathComponent()) == .outsideAllowedLocations)
        #expect(check(deep.deletingLastPathComponent().deletingLastPathComponent()) == nil)
        #expect(check(other) == .outsideAllowedLocations)
        #expect(check(system.appending(path: "Library/LaunchDaemons")) == .outsideAllowedLocations)
    }

    @Test func rejectsAppleDataButAllowsAppleCachesAndLogs() throws {
        let home = try FakeHome()
        defer { home.remove() }
        for path in ["Library/Preferences/com.apple.Safari.plist", "Library/Containers/com.apple.Notes/x",
                     "Library/Group Containers/group.com.apple.notes/x", "Library/Application Support/com.apple.TCC/x"] {
            let url = home.url.appending(path: path.split(separator: "/").prefix(3).joined(separator: "/"))
            try home.file(path)
            #expect(TrashPolicy.check(url, home: home.url, applicationRoots: []) == .systemData, "\(path)")
        }
        for path in ["Library/Caches/com.apple.Safari", "Library/Logs/com.apple.xpc.launchd"] {
            try home.file("\(path)/x")
            #expect(TrashPolicy.check(home.url.appending(path: path), home: home.url, applicationRoots: []) == nil, "\(path)")
        }
    }
}

@Suite struct LeftoverFinderTests {
    @Test func findsLeftoversByBundleIDAndNameWithLabels() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let plist = try home.file("Apps/Thing.app/Contents/Info.plist")
        try (["CFBundleIdentifier": "com.example.thing", "CFBundleName": "Thing", "CFBundleExecutable": "ThingApp"] as NSDictionary)
            .write(to: plist)
        try home.file("Library/Preferences/com.example.thing.plist")
        try home.file("Library/Caches/com.example.thing/data")
        try home.file("Library/Application Support/com.example.thing/db.sqlite")
        try home.file("Library/Application Support/Thing/db.sqlite")
        try home.file("Library/Containers/com.example.thing/Data/x")
        try home.file("Library/Group Containers/ABCDE12345.com.example.thing/x")
        try home.file("Library/Application Scripts/com.example.thing/s.scpt")
        try home.file("Library/Saved Application State/com.example.thing.savedState/w")
        try home.file("Library/LaunchAgents/com.example.thing.plist")
        try home.file("Library/Logs/DiagnosticReports/ThingApp-2026-09-27-120000.ips")
        try home.file("Library/Logs/DiagnosticReports/OtherApp-2026-09-27-120000.ips")
        try home.file("Library/Preferences/com.example.thingamajig.plist")
        try home.file("Library/Application Support/Other/x")

        let app = InstalledApp(url: home.url.appending(path: "Apps/Thing.app"))
        let result = LeftoverFinder.find(for: app, home: home.url, systemRoot: home.url.appending(path: "NoSystem"))
        let labels = Dictionary(uniqueKeysWithValues: result.items.map {
            ($0.url.deletingLastPathComponent().lastPathComponent + "/" + $0.name, $0.safety)
        })

        #expect(result.items.first?.name == "Thing.app")
        #expect(labels == [
            "Apps/Thing.app": .review,
            "Preferences/com.example.thing.plist": .safe,
            "Caches/com.example.thing": .regenerates,
            "Application Support/com.example.thing": .appData,
            "Application Support/Thing": .review,
            "Containers/com.example.thing": .appData,
            "Group Containers/ABCDE12345.com.example.thing": .appData,
            "Application Scripts/com.example.thing": .appData,
            "Saved Application State/com.example.thing.savedState": .safe,
            "LaunchAgents/com.example.thing.plist": .appData,
            "DiagnosticReports/ThingApp-2026-09-27-120000.ips": .safe,
        ])
    }

    @Test func findsSystemWideLeftovers() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let plist = try home.file("Apps/Thing.app/Contents/Info.plist")
        try (["CFBundleIdentifier": "com.example.thing", "CFBundleName": "Thing"] as NSDictionary).write(to: plist)
        try home.file("System/Library/LaunchDaemons/com.example.thing.plist")
        try home.file("System/Library/LaunchDaemons/com.example.thing.helper.plist")
        try home.file("System/Library/PrivilegedHelperTools/com.example.thing.helper")
        try home.file("System/Library/Application Support/Thing/x")

        let app = InstalledApp(url: home.url.appending(path: "Apps/Thing.app"))
        let result = LeftoverFinder.find(for: app, home: home.url.appending(path: "Home"), systemRoot: home.url.appending(path: "System"))
        let labels = Dictionary(uniqueKeysWithValues: result.items.map { ($0.name, $0.safety) })

        #expect(labels == [
            "Thing.app": .review,
            "com.example.thing.plist": .appData,
            "com.example.thing.helper.plist": .review,
            "com.example.thing.helper": .review,
            "Thing": .review,
        ])
    }

    @Test func siblingAppsWithALongerIdentifierNeedReview() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let plist = try home.file("Apps/IDEA.app/Contents/Info.plist")
        try (["CFBundleIdentifier": "com.jetbrains.intellij", "CFBundleName": "IntelliJ IDEA"] as NSDictionary).write(to: plist)
        try home.file("Library/Preferences/com.jetbrains.intellij.plist")
        try home.file("Library/Preferences/com.jetbrains.intellij.ce.plist")
        try home.file("Library/Caches/com.jetbrains.intellij.ce/x")
        try home.file("Library/Group Containers/NOTATEAMIDX1.com.jetbrains.intellij/x")

        let app = InstalledApp(url: home.url.appending(path: "Apps/IDEA.app"))
        let labels = Dictionary(uniqueKeysWithValues: LeftoverFinder.find(for: app, home: home.url, systemRoot: home.url.appending(path: "NoSystem")).items.map { ($0.name, $0.safety) })

        #expect(labels == [
            "IDEA.app": .review,
            "com.jetbrains.intellij.plist": .safe,
            "com.jetbrains.intellij.ce.plist": .review,
            "com.jetbrains.intellij.ce": .review,
        ])
    }

    @Test func appleAppsGetNoLeftovers() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let plist = try home.file("Apps/Safari.app/Contents/Info.plist")
        try (["CFBundleIdentifier": "com.apple.Safari", "CFBundleName": "Safari"] as NSDictionary).write(to: plist)
        try home.file("Library/Preferences/com.apple.Safari.plist")
        try home.file("Library/Caches/com.apple.Safari/x")

        let app = InstalledApp(url: home.url.appending(path: "Apps/Safari.app"))

        #expect(app.isAppleApp)
        #expect(LeftoverFinder.find(for: app, home: home.url, systemRoot: home.url).items.map(\.name) == ["Safari.app"])
    }
}
