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
