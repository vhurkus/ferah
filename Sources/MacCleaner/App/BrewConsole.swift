import AppKit
import CleanerCore
import Observation

/// Runs one brew command at a time and shows its output as it comes.
@MainActor @Observable
final class BrewConsole {
    private(set) var title = ""
    private(set) var command = ""
    private(set) var output = ""
    private(set) var isRunning = false
    private(set) var succeeded: Bool?
    /// The command stopped at a password prompt it can't show: it has to run in Terminal.
    private(set) var needsTerminal = false

    func run(_ brew: Homebrew, _ arguments: [String], title: String, finished: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        self.title = title
        command = (["brew"] + arguments).joined(separator: " ")
        output = ""
        succeeded = nil
        needsTerminal = false
        isRunning = true

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew.executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.merge(brew.environment) { _, new in new }
        environment["HOMEBREW_NO_AUTO_UPDATE"] = nil
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor [weak self] in self?.output += text }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor [weak self] in
                pipe.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                self.isRunning = false
                self.succeeded = status == 0
                let lower = self.output.lowercased()
                self.needsTerminal = status != 0 && (lower.contains("sudo") || lower.contains("a terminal is required")
                                                     || lower.contains("password"))
                finished()
            }
        }
        do {
            try process.run()
        } catch {
            output = error.localizedDescription
            isRunning = false
            succeeded = false
        }
    }

    func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    func openTerminal() {
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: terminal, configuration: .init())
        }
    }

    func dismiss() {
        guard !isRunning else { return }
        succeeded = nil
        output = ""
        title = ""
    }
}
