import AppKit
import CleanerCore

struct TrashOutcome {
    struct Failure: Identifiable {
        let url: URL
        let reason: String
        var id: URL { url }
    }

    var moved: Set<URL> = []
    var movedBytes: Int64 = 0
    var failures: [Failure] = []
}

/// Moves items to the Trash, one by one, after the safety policy approves each path.
/// Uses NSWorkspace so Finder's "Put Back" works. Items the user can't move themselves (apps installed
/// by the App Store, files in /Library) go through Finder, which asks for an administrator password once.
/// Nothing is ever deleted permanently.
@MainActor
enum TrashService {
    static func moveToTrash(_ items: [ScanItem], home: URL, applicationRoots: [URL]) async -> TrashOutcome {
        var outcome = TrashOutcome()
        var needsFinder: [ScanItem] = []

        for item in items {
            if let rejection = TrashPolicy.check(item.url, home: home, applicationRoots: applicationRoots) {
                outcome.failures.append(.init(url: item.url, reason: rejection.message))
                continue
            }
            stopLaunchAgentIfNeeded(item.url, home: home)
            if needsAdministrator(item.url) {
                needsFinder.append(item)
                continue
            }
            do {
                _ = try await NSWorkspace.shared.recycle([item.url])
                outcome.moved.insert(item.url)
                outcome.movedBytes += item.bytes
            } catch where FileWalker.isPermissionError(error) || isWritePermissionError(error) {
                needsFinder.append(item)
            } catch {
                outcome.failures.append(.init(url: item.url, reason: error.localizedDescription))
            }
        }

        if !needsFinder.isEmpty {
            let failure = await FinderTrash.move(needsFinder.map(\.url))
            for item in needsFinder {
                if !FileManager.default.fileExists(atPath: item.url.path) {
                    outcome.moved.insert(item.url)
                    outcome.movedBytes += item.bytes
                } else {
                    outcome.failures.append(.init(url: item.url, reason: failure ?? String(localized: "Finder couldn't move it.")))
                }
            }
        }
        return outcome
    }

    /// The user can't move it without an administrator: its folder, or the item itself when it's a
    /// folder (moving a folder rewrites its link to the parent), isn't writable.
    static func needsAdministrator(_ url: URL) -> Bool {
        let fm = FileManager.default
        if !fm.isWritableFile(atPath: url.deletingLastPathComponent().path) { return true }
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && !fm.isWritableFile(atPath: url.path)
    }

    /// A launch agent keeps running after its plist is gone, so unload it first. Failure is fine:
    /// most agents aren't loaded, and a loaded one still stops at the next login.
    static func stopLaunchAgentIfNeeded(_ url: URL, home: URL) {
        guard url.pathExtension == "plist",
              url.deletingLastPathComponent().path == home.appending(path: "Library/LaunchAgents").path
        else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    static func isWritePermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteNoPermissionError
    }

    /// The Trash's current size, or nil when macOS doesn't let the app read it (no Full Disk Access).
    nonisolated static func trashSize() async -> Int64? {
        await Task.detached {
            let trash = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
            guard (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) != nil else { return nil }
            return FileWalker.allocatedSize(of: trash, log: UnreadableLog())
        }.value
    }

    /// Empties the Trash through Finder, like Finder › Empty Trash. Returns an error message on failure.
    static func emptyTrash() async -> String? {
        await FinderTrash.run(["tell application \"Finder\" to empty the trash"], arguments: [])
    }

    static func openTrash() {
        let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
        if let trash { NSWorkspace.shared.open(trash) }
    }
}

/// Talks to Finder through `osascript`. Paths travel as arguments, never inside the script text.
enum FinderTrash {
    /// Moves the items to the Trash in one Finder call, so an administrator password is asked once.
    /// Returns an error message, or nil when Finder reported success.
    static func move(_ urls: [URL]) async -> String? {
        await run([
            "on run argv",
            "set theItems to {}",
            "repeat with p in argv",
            "set end of theItems to (POSIX file (p as text)) as alias",
            "end repeat",
            // Finder may ask for an administrator password: bring it forward so the prompt is seen,
            // and give the user time to answer it.
            "tell application \"Finder\"",
            "activate",
            "with timeout of 600 seconds",
            "delete theItems",
            "end timeout",
            "end tell",
            "end run",
        ], arguments: urls.map(\.path))
    }

    static func run(_ lines: [String], arguments: [String]) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = lines.flatMap { ["-e", $0] } + arguments
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return error.localizedDescription
            }
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return nil }
            let message = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return describe(message)
        }.value
    }

    /// osascript errors end in their code, e.g. "execution error: User canceled. (-128)".
    static func describe(_ message: String) -> String {
        if message.contains("(-128)") {
            return String(localized: "The administrator password prompt was cancelled.")
        }
        if message.contains("(-1712)") {
            return String(localized: "Finder didn't answer in time. Try again and answer Finder's password prompt.")
        }
        if message.contains("(-1743)") || message.contains("(-10004)") {
            return String(localized: "Ferah isn't allowed to control Finder. Allow it in System Settings › Privacy & Security › Automation.")
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Finder couldn't move it.") : trimmed
    }
}

extension TrashPolicy.Rejection {
    var message: String {
        switch self {
        case .missing: String(localized: "It no longer exists.")
        case .outsideAllowedLocations: String(localized: "It's outside your home folder.")
        case .protectedLocation: String(localized: "This folder is protected.")
        case .systemApp: String(localized: "It's part of macOS.")
        case .systemData: String(localized: "It belongs to macOS or one of Apple's apps.")
        }
    }
}
