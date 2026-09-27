import Foundation
import Testing
@testable import CleanerCore

@Suite struct StorageAnalyzerTests {
    /// Allocated size as the analyzer sees it (APFS rounds up to whole blocks).
    func allocated(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return Int64(values.totalFileAllocatedSize ?? 0)
    }

    @Test func measuresEveryFolderAndGroupsSmallFiles() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let big = try home.file("Root/Docs/big.bin", bytes: 300_000)
        let deep = try home.file("Root/Docs/Deep/deep.bin", bytes: 200_000)
        let small1 = try home.file("Root/Docs/a.txt", bytes: 1000)
        let small2 = try home.file("Root/Docs/b.txt", bytes: 1000)
        let top = try home.file("Root/top.bin", bytes: 150_000)

        let map = StorageAnalyzer.map([home.url.appending(path: "Root")], minimumFileSize: 100_000)
        let root = map.roots[0]
        let docs = root.appending(path: "Docs")
        let docsTotal = try allocated(big) + allocated(deep) + allocated(small1) + allocated(small2)

        #expect(map.size(of: root) == docsTotal + (try allocated(top)))
        #expect(map.size(of: docs) == docsTotal)
        #expect(map.entries(in: root)?.map(\.name) == ["Docs", "top.bin"])
        let docEntries: [StorageEntry] = map.entries(in: docs) ?? []
        #expect(docEntries.map(\.name) == ["big.bin", "Deep", ".ferah-small-files"])
        #expect(docEntries.last?.kind == StorageEntry.Kind.smallFiles(count: 2))
        #expect(docEntries.last?.bytes == (try allocated(small1) + allocated(small2)))
    }

    @Test func removingShrinksEveryFolderAbove() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let deep = try home.file("Root/A/B/deep.bin", bytes: 400_000)
        try home.file("Root/A/other.bin", bytes: 200_000)
        let before = StorageAnalyzer.map([home.url.appending(path: "Root")], minimumFileSize: 100_000)
        let root = before.roots[0]
        let a = root.appending(path: "A"), b = a.appending(path: "B")
        let after = before.removing(b)
        let removed = try allocated(deep)

        #expect(after.size(of: root) == before.size(of: root)! - removed)
        #expect(after.size(of: a) == before.size(of: a)! - removed)
        #expect(after.entries(in: a)?.map(\.name) == ["other.bin"])
        #expect(after.entries(in: root)?.first?.bytes == after.size(of: a))
        #expect(after.entries(in: b) == nil)
    }

    @Test func doesNotFollowSymlinks() throws {
        let home = try FakeHome()
        defer { home.remove() }
        try home.file("Outside/huge.bin", bytes: 500_000)
        try home.file("Root/x.bin", bytes: 1000)
        let root = home.url.appending(path: "Root")
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: home.url.appending(path: "Outside"))

        let map = StorageAnalyzer.map([root], minimumFileSize: 100_000)

        #expect((map.size(of: map.roots[0]) ?? .max) < 100_000)
    }
}
