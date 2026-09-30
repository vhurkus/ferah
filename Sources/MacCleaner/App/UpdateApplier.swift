import AppKit
import CleanerCore

/// Puts a verified update in place of the installed app, without ever leaving the user with neither:
/// the new copy lands next to the old one first, then the old one goes to the Trash, then the new one takes its name.
@MainActor
enum UpdateApplier {
    /// Returns an error message, or nil when the new version is in place.
    static func install(_ newApp: URL, replacing old: URL, model: AppModel) async -> String? {
        let fm = FileManager.default
        let beside = old.deletingLastPathComponent().appending(path: ".\(old.deletingPathExtension().lastPathComponent)-ferah-update.app")
        try? fm.removeItem(at: beside)
        defer { try? fm.removeItem(at: newApp.deletingLastPathComponent()) }

        // 1. Next to the old app. If this fails, nothing has changed.
        do {
            try fm.copyItem(at: newApp, to: beside)
        } catch {
            if let failure = await AdminRunner.run([["/usr/bin/ditto", newApp.path, beside.path]],
                                                   prompt: String(localized: "Ferah wants to install an app update.")) {
                return failure
            }
        }
        // 2. The old app to the Trash, so it can be put back.
        let outcome = await TrashService.moveToTrash([ScanItem(url: old, bytes: 0, safety: .review)],
                                                     home: model.home, applicationRoots: model.applicationRoots)
        guard outcome.moved.contains(old) else {
            try? fm.removeItem(at: beside)
            return outcome.failures.first?.reason ?? String(localized: "The old version couldn't be moved to the Trash.")
        }
        // 3. The new app takes the old one's name.
        do {
            try fm.moveItem(at: beside, to: old)
        } catch {
            if let failure = await AdminRunner.run([["/bin/mv", beside.path, old.path]],
                                                   prompt: String(localized: "Ferah wants to install an app update.")) {
                return String(localized: "The new version is at \(beside.path). \(failure)")
            }
        }
        NSWorkspace.shared.noteFileSystemChanged(old.path)
        return nil
    }

    static func message(for failure: UpdateInstaller.Failure) -> String {
        switch failure {
        case .downloadFailed: String(localized: "The download didn't finish. Check your connection and try again.")
        case .checksumMismatch: String(localized: "The download doesn't match its published checksum, so it wasn't installed.")
        case .signatureInvalid: String(localized: "The download's signature doesn't match the app's, so it wasn't installed.")
        case .unsupportedArchive: String(localized: "This update comes in a form Ferah can't install. Use the download page.")
        case .noAppInside: String(localized: "The download doesn't contain the app. Use the download page.")
        case .installedAppUnsigned: String(localized: "The installed app has no developer signature to compare with, so Ferah won't replace it.")
        case .differentDeveloper: String(localized: "The download is signed by a different developer than the installed app, so it wasn't installed.")
        case .notNotarized: String(localized: "macOS doesn't accept the downloaded app (it isn't notarized), so it wasn't installed.")
        case .unexpectedVersion(let expected, let found):
            String(localized: "The download is version \(found ?? "?"), not \(expected), so it wasn't installed.")
        }
    }
}
