import Foundation
import Testing
@testable import CleanerCore

@Suite struct DuplicateTests {
    func write(_ home: FakeHome, _ path: String, _ data: Data, modified: Date? = nil) throws -> URL {
        let url = home.url.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    @Test func findsIdenticalFilesOnly() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let content = Data((0..<200_000).map { UInt8($0 % 251) })
        var different = content
        different[150_000] ^= 0xFF  // same size, same first 64 KB, different later
        let old = try write(home, "Downloads/report.pdf", content, modified: Date(timeIntervalSinceNow: -86_400))
        let copy = try write(home, "Desktop/report copy.pdf", content)
        _ = try write(home, "Documents/report-v2.pdf", different)
        _ = try write(home, "Documents/small-a.txt", Data(repeating: 7, count: 100))
        _ = try write(home, "Documents/small-b.txt", Data(repeating: 7, count: 100))
        let original = try write(home, "Documents/linked.bin", Data(repeating: 3, count: 150_000))
        try FileManager.default.linkItem(at: original, to: home.url.appending(path: "Documents/linked-hardlink.bin"))

        let groups = DuplicateFinder.find(in: [home.url], minimumSize: 50_000)

        #expect(groups.count == 1)
        #expect(groups.first?.copies.map { $0.url.lastPathComponent } == [old.lastPathComponent, copy.lastPathComponent])
        #expect((groups.first?.wastedBytes ?? 0) > 0)
        #expect(DuplicateFinder.allButOldest(groups).map(\.lastPathComponent) == ["report copy.pdf"])
    }
}
