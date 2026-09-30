import Foundation
import Testing
@testable import CleanerCore

@Suite struct SystemDataTests {
    @Test func readsSnapshotDatesAndRejectsAnythingElse() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-09-27-101500.local
        com.apple.TimeMachine.2026-09-27-111500.local
        com.apple.TimeMachine.2026-09-27'; rm -rf ~; '.local
        something.else
        """
        #expect(SystemDataInspector.snapshotDates(in: output) == ["2026-09-27-101500", "2026-09-27-111500"])
    }

    @Test func readsDeletableRuntimesLargestFirst() {
        let json = """
        {
          "A": {"identifier": "A", "deletable": true, "version": "26.5", "build": "23F77", "sizeBytes": 100,
                "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "lastUsedAt": "2026-07-16T17:54:28Z"},
          "B": {"identifier": "B", "deletable": true, "version": "27.0", "build": "24A434", "sizeBytes": 200,
                "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-27-0"},
          "C": {"identifier": "C", "deletable": false, "version": "1", "sizeBytes": 999}
        }
        """
        let items = SystemDataInspector.parseRuntimes(json)
        #expect(items.map(\.title) == ["watchOS 27.0", "iOS 26.5"])
        #expect(items.last?.lastUsed != nil)
        #expect(items.first?.kind == .simulatorRuntime(identifier: "B"))
    }

    @Test func countsUnavailableSimulators() {
        let json = """
        {"devices": {"r1": [{"isAvailable": false, "dataPathSize": 10}, {"isAvailable": true, "dataPathSize": 99}],
                     "r2": [{"isAvailable": false, "dataPathSize": 5}]}}
        """
        let item = SystemDataInspector.parseUnavailable(json)
        #expect(item?.kind == .unavailableSimulators(count: 2))
        #expect(item?.bytes == 15)
        #expect(SystemDataInspector.parseUnavailable(#"{"devices": {}}"#) == nil)
    }

    @Test func findsDeviceBackupsWithTheirNames() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let info = try home.file("Library/Application Support/MobileSync/Backup/00008110-ABC/Info.plist")
        try (["Device Name": "Hüseyin's iPhone", "Product Name": "iPhone 17", "Last Backup Date": Date()] as NSDictionary).write(to: info)
        try home.file("Library/Application Support/MobileSync/Backup/00008110-ABC/Manifest.db", bytes: 50_000)

        let backups = SystemDataInspector(runner: ProcessRunner(), home: home.url, developerDirectory: nil).deviceBackups()

        #expect(backups.map(\.title) == ["Hüseyin's iPhone"])
        #expect(backups.first?.detail == "iPhone 17")
        #expect((backups.first?.bytes ?? 0) > 50_000)
    }
}

@Suite struct BatteryTests {
    @Test func prefersSettingsFiguresAndReadsLiveState() {
        let registry: [String: Any] = [
            "CycleCount": 170, "DesignCycleCount9C": 1000, "CurrentCapacity": 88, "IsCharging": false,
            "ExternalConnected": false, "AvgTimeToEmpty": 795, "Voltage": 12602,
            "Amperage": NSNumber(value: UInt64(bitPattern: -512)),
            "BatteryData": ["DesignCapacity": 6249, "NominalChargeCapacity": 5679],
        ]
        let profiler = """
        {"SPPowerDataType": [{"sppower_battery_health_info": {"sppower_battery_cycle_count": 174,
          "sppower_battery_health": "Good", "sppower_battery_health_maximum_capacity": "%94"}}]}
        """
        let battery = BatteryReader.parse(registry: registry, profiler: profiler)

        #expect(battery.maximumCapacityPercent == 94)
        #expect(battery.cycleCount == 174)
        #expect(battery.condition == "Good")
        #expect(battery.minutesRemaining == 795)
        #expect(abs((battery.watts ?? 0) + 6.45) < 0.01)
        #expect(!battery.needsService)
    }

    @Test func fallsBackToRawCapacityAndIgnoresEstimating() {
        let registry: [String: Any] = [
            "CycleCount": 10, "CurrentCapacity": 50, "AvgTimeToEmpty": 65535,
            "BatteryData": ["DesignCapacity": 1000, "NominalChargeCapacity": 910],
        ]
        let battery = BatteryReader.parse(registry: registry, profiler: "")
        #expect(battery.maximumCapacityPercent == 91)
        #expect(battery.minutesRemaining == nil)
    }

    @Test func readsTheLastTopSample() {
        let output = """
        PID    POWER COMMAND
        413    0.0   WindowServer
        PID    POWER COMMAND
        413    24.2  WindowServer
        15550  7.1   top
        15433  2.5   Preview
        6169   0.0   Safari
        7263   1.1   Claude Helper (Renderer)
        """
        let users = BatteryReader.parseTop(output)
        #expect(users.map(\.command) == ["WindowServer", "Preview", "Claude Helper (Renderer)"])
    }
}

@Suite struct ForgottenDownloadTests {
    func app(_ home: FakeHome, _ path: String, id: String, version: String = "1") throws -> URL {
        let plist = try home.file("\(path)/Contents/Info.plist")
        try (["CFBundleIdentifier": id, "CFBundleShortVersionString": version] as NSDictionary).write(to: plist)
        return home.url.appending(path: path)
    }

    @Test func findsInstallersFirmwareAndExtraXcodes() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let apps = home.url.appending(path: "Apps")
        _ = try app(home, "Apps/Install macOS Sequoia.app", id: "com.apple.InstallAssistant.macOSSequoia", version: "15.6")
        let active = try app(home, "Apps/Xcode.app", id: "com.apple.dt.Xcode", version: "26.0")
        _ = try app(home, "Apps/Xcode-15.4.app", id: "com.apple.dt.Xcode", version: "15.4")
        _ = try app(home, "Apps/Safari.app", id: "com.apple.Safari")
        try home.file("Library/iTunes/iPhone Software Updates/iPhone17,1_26.0_Restore.ipsw", bytes: 20_000)

        let inspector = SystemDataInspector(runner: ProcessRunner(), home: home.url,
                                            developerDirectory: active.appending(path: "Contents/Developer").path,
                                            applicationFolder: apps, systemRoot: home.url.appending(path: "NoSystem"))

        #expect(inspector.macOSInstallers().map(\.title) == ["Install macOS Sequoia"])
        #expect(inspector.extraXcodes().map(\.title) == ["Xcode-15.4"])
        #expect(inspector.deviceFirmware().map(\.title) == ["iPhone17,1_26.0_Restore"])
    }

    @Test func policyAllowsInstallersAndXcodeOnlyInApplicationFolders() throws {
        let base = try FakeHome()
        defer { base.remove() }
        let home = base.url.appending(path: "Home")
        try base.file("Home/.keep")
        let apps = base.url.appending(path: "Apps")
        let installer = try app(base, "Apps/Install macOS Sequoia.app", id: "com.apple.InstallAssistant.macOSSequoia")
        let xcode = try app(base, "Apps/Xcode-15.4.app", id: "com.apple.dt.Xcode")
        let safari = try app(base, "Apps/Safari.app", id: "com.apple.Safari")
        let stray = try app(base, "Home/Downloads/Install macOS Sequoia.app", id: "com.apple.InstallAssistant.macOSSequoia")

        #expect(TrashPolicy.check(installer, home: home, applicationRoots: [apps]) == nil)
        #expect(TrashPolicy.check(xcode, home: home, applicationRoots: [apps]) == nil)
        #expect(TrashPolicy.check(safari, home: home, applicationRoots: [apps]) == .systemApp)
        #expect(TrashPolicy.check(stray, home: home, applicationRoots: [apps]) == .systemApp)
    }
}
