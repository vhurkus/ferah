import Foundation
import Testing
@testable import CleanerCore

@Suite struct BackgroundItemTests {
    @Test func readsDisabledLabels() {
        let output = """
        disabled services = {
            "com.adobe.GC.AGM" => enabled
            "com.epicgames.launcher" => disabled
            "com.riot.riotclient.checkinstalls" => disabled
        }
        """
        #expect(BackgroundItemFinder.disabledLabels(in: output) == ["com.epicgames.launcher", "com.riot.riotclient.checkinstalls"])
    }

    func app(_ home: FakeHome, _ name: String, _ id: String) throws -> InstalledApp {
        let plist = try home.file("Apps/\(name).app/Contents/Info.plist")
        try (["CFBundleIdentifier": id, "CFBundleName": name] as NSDictionary).write(to: plist)
        return InstalledApp(url: home.url.appending(path: "Apps/\(name).app"))
    }

    @Test func findsOwnersFourWays() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let forti = try app(home, "FortiClient", "com.fortinet.FortiClient")
        let docker = try app(home, "Docker", "com.docker.docker")
        let zoom = try app(home, "zoom.us", "us.zoom.xos")
        let apps = [forti, docker, zoom]

        #expect(BackgroundItemFinder.owner(label: "x.y.z", program: nil, associated: ["us.zoom.xos"], installedApps: apps)?.name == "zoom.us")
        #expect(BackgroundItemFinder.owner(label: "x.y.z", program: docker.url.path + "/Contents/MacOS/helper",
                                           associated: nil, installedApps: apps)?.name == "Docker")
        #expect(BackgroundItemFinder.owner(label: "com.fortinet.fctctl", program: "/Library/Application Support/Fortinet/bin/fctctld",
                                           associated: nil, installedApps: apps)?.name == "FortiClient")
        #expect(BackgroundItemFinder.owner(label: "com.gone.agent", program: "/opt/gone/bin/agent", associated: nil, installedApps: apps) == nil)
    }

    @Test func findsTheAppInLauncherArgumentsAndIgnoresUninstallers() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let forti = try app(home, "FortiClient", "com.fortinet.FortiClient")
        let uninstaller = try app(home, "FortiClientUninstaller", "com.fortinet.Uninstall")
        let plist = try home.file("Library/LaunchAgents/com.fortinet.fortiagent.plist")
        try (["Label": "com.fortinet.fortiagent",
              "ProgramArguments": ["/usr/bin/open", "-W", forti.url.path + "/Contents/Resources/Agent.app"]] as NSDictionary).write(to: plist)

        let item = BackgroundItemFinder.item(at: plist, scope: .allUsers, installedApps: [forti, uninstaller], disabled: [])
        #expect(item?.ownerName == "FortiClient")
        #expect(BackgroundItemFinder.owner(label: "com.fortinet.other", program: nil, associated: nil,
                                           installedApps: [forti, uninstaller])?.name == "FortiClient")
    }

    @Test func marksItemsWhoseProgramIsGone() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let plist = try home.file("Library/LaunchAgents/com.gone.agent.plist")
        try (["Label": "com.gone.agent", "Program": "/nonexistent/agent", "RunAtLoad": true] as NSDictionary).write(to: plist)

        let item = try #require(BackgroundItemFinder.item(at: plist, scope: .user, installedApps: [], disabled: ["com.gone.agent"]))

        #expect(item.isBroken)
        #expect(item.isDisabled)
        #expect(item.runsAtLoad)
        #expect(item.ownerName == nil)
    }
}
