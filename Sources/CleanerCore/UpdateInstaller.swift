import CryptoKit
import Foundation

/// Downloads an update and proves it's genuine before anything is replaced:
/// the archive matches its published checksum (or Sparkle signature), and the app inside is signed
/// by the same developer as the installed one, notarized, and the expected version.
public struct UpdateInstaller: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case downloadFailed
        case checksumMismatch
        case signatureInvalid
        case unsupportedArchive
        case noAppInside
        /// The installed app has no developer signature to compare with.
        case installedAppUnsigned
        case differentDeveloper(expected: String, found: String?)
        case notNotarized
        case unexpectedVersion(expected: String, found: String?)
    }

    public let runner: CommandRunner
    public let download: Download

    /// Downloads a file, reporting how much of it has arrived (0...1), and returns where it was saved.
    public typealias Download = @Sendable (URL, _ progress: @escaping @Sendable (Double) -> Void) async -> URL?

    /// Where `prepare` has got to, for showing progress.
    public enum Stage: Sendable, Equatable {
        case downloading(Double)
        case verifying
    }

    public init(runner: CommandRunner = ProcessRunner(), download: @escaping Download = UpdateInstaller.downloadFile) {
        self.runner = runner
        self.download = download
    }

    public static let downloadFile: Download = { url, progress in
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Ferah (+https://github.com/vhurkus/ferah)", forHTTPHeaderField: "User-Agent")
        let observer = ProgressObserver(report: progress)
        guard let (file, response) = try? await URLSession.shared.download(for: request, delegate: observer),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false
        else { return nil }
        // URLSession deletes its file when this returns; keep a copy.
        let kept = FileManager.default.temporaryDirectory.appending(path: "ferah-update-\(UUID().uuidString)")
        do { try FileManager.default.moveItem(at: file, to: kept) } catch { return nil }
        return kept
    }

    /// Watches the download task's progress; the async download API has no progress callback of its own.
    private final class ProgressObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let report: @Sendable (Double) -> Void
        private var observation: NSKeyValueObservation?

        init(report: @escaping @Sendable (Double) -> Void) { self.report = report }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
                report(progress.fractionCompleted)
            }
        }
    }

    /// Returns the verified new app, staged in a temporary folder, ready to replace the installed one.
    public func prepare(_ update: AppUpdate, installed app: InstalledApp,
                        stage: @escaping @Sendable (Stage) -> Void = { _ in }) async throws(Failure) -> URL {
        guard let package = update.package else { throw .unsupportedArchive }
        guard let expectedTeam = await teamIdentifier(of: app.url) else { throw .installedAppUnsigned }
        stage(.downloading(0))
        guard let archive = await download(package.url, { stage(.downloading($0)) }) else { throw .downloadFailed }
        stage(.verifying)
        defer { try? FileManager.default.removeItem(at: archive) }

        if let expected = package.sha256 {
            guard Self.sha256(of: archive)?.lowercased() == expected.lowercased() else { throw .checksumMismatch }
        }
        if let signature = package.edSignature, let key = app.sparklePublicKey {
            guard Self.isValidEdSignature(signature, publicKey: key, file: archive) else { throw .signatureInvalid }
        }

        let staging = FileManager.default.temporaryDirectory.appending(path: "ferah-staging-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let newApp = try await extract(archive, into: staging, preferring: package.appFileName ?? app.url.lastPathComponent)

        let team = await teamIdentifier(of: newApp)
        guard team == expectedTeam else { throw .differentDeveloper(expected: expectedTeam, found: team) }
        guard await runner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]).succeeded,
              await runner.run("/usr/sbin/spctl", ["--assess", "--type", "execute", newApp.path]).succeeded
        else { throw .notNotarized }
        let version = InstalledApp.info(of: newApp)["CFBundleShortVersionString"] as? String
        guard let version, !VersionNumber.isNewer(update.latestVersion, than: version) else {
            throw .unexpectedVersion(expected: update.latestVersion, found: version)
        }
        return newApp
    }

    /// The Team ID of the app's developer signature, or nil when it's unsigned or ad hoc.
    public func teamIdentifier(of app: URL) async -> String? {
        let result = await runner.run("/usr/bin/codesign", ["-dv", app.path])
        return Self.teamIdentifier(inCodesignOutput: result.error + result.output)
    }

    static func teamIdentifier(inCodesignOutput output: String) -> String? {
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }) else { return nil }
        let team = String(line.dropFirst("TeamIdentifier=".count))
        return team == "not set" || team.isEmpty ? nil : team
    }

    // MARK: Archives

    func extract(_ archive: URL, into staging: URL, preferring name: String) async throws(Failure) -> URL {
        if Self.isZip(archive) {
            guard await runner.run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path]).succeeded else { throw .unsupportedArchive }
        } else {
            // A disk image: mount it read-only and out of sight, copy the app, then eject.
            let mount = staging.appending(path: ".mount")
            guard await runner.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-noautoopen",
                                                         "-mountpoint", mount.path, archive.path]).succeeded
            else { throw .unsupportedArchive }
            let found = Self.findApp(in: mount, preferring: name)
            if let found {
                _ = await runner.run("/usr/bin/ditto", [found.path, staging.appending(path: found.lastPathComponent).path])
            }
            _ = await runner.run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
            guard found != nil else { throw .noAppInside }
        }
        guard let app = Self.findApp(in: staging, preferring: name) else { throw .noAppInside }
        return app
    }

    static func isZip(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04])
    }

    /// The app named `name`, else the only app, within two folder levels. Never follows symlinks:
    /// disk images carry one to /Applications, which would otherwise find the installed app itself.
    static func findApp(in folder: URL, preferring name: String) -> URL? {
        var apps: [URL] = []
        func look(_ url: URL, depth: Int) {
            let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
            for child in children {
                if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
                if child.pathExtension == "app" {
                    apps.append(child)
                } else if depth > 0, child.lastPathComponent != "__MACOSX" {
                    look(child, depth: depth - 1)
                }
            }
        }
        look(folder, depth: 2)
        return apps.first { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame } ?? (apps.count == 1 ? apps[0] : nil)
    }

    // MARK: Checks

    static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func isValidEdSignature(_ signature: String, publicKey: String, file: URL) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey), let signatureData = Data(base64Encoded: signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe)
        else { return false }
        return key.isValidSignature(signatureData, for: data)
    }
}
