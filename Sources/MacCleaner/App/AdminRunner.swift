import Foundation

/// Runs commands as root after macOS asks for an administrator password (outside the App Store only).
/// Each argument is shell-quoted, and the script reaches osascript as an argument, never as script text.
enum AdminRunner {
    /// Runs all the commands in order; the last one decides success (earlier steps, like stopping
    /// something that isn't running, may fail harmlessly). Returns an error message, or nil on success.
    static func run(_ commands: [[String]], prompt: String) async -> String? {
        let script = commands.map { $0.map(shellQuote).joined(separator: " ") }.joined(separator: "; ")
        return await FinderTrash.run([
            "on run argv",
            "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
            "end run",
        ], arguments: [script, prompt])
    }

    static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
