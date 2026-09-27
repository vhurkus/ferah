import Foundation

/// Result of running a command-line tool.
public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    public let output: String
    public let error: String

    public var succeeded: Bool { status == 0 }

    public init(status: Int32, output: String, error: String) {
        self.status = status
        self.output = output
        self.error = error
    }
}

/// Runs command-line tools (tmutil, simctl, launchctl, brew). A protocol so tests can supply canned output.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String], environment: [String: String]) async -> CommandResult
}

extension CommandRunner {
    public func run(_ executable: String, _ arguments: [String]) async -> CommandResult {
        await run(executable, arguments, environment: [:])
    }
}

/// Runs tools as child processes. Arguments are passed as an array, never through a shell.
public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], environment: [String: String]) async -> CommandResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            env.merge(environment) { _, new in new }
            process.environment = env
            let output = Pipe(), error = Pipe()
            process.standardOutput = output
            process.standardError = error
            process.standardInput = FileHandle.nullDevice

            // Read while the process runs: a full pipe would otherwise block it forever.
            let outputData = DataCollector(), errorData = DataCollector()
            output.fileHandleForReading.readabilityHandler = { outputData.append($0.availableData) }
            error.fileHandleForReading.readabilityHandler = { errorData.append($0.availableData) }

            process.terminationHandler = { process in
                output.fileHandleForReading.readabilityHandler = nil
                error.fileHandleForReading.readabilityHandler = nil
                outputData.append(output.fileHandleForReading.readDataToEndOfFile())
                errorData.append(error.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    output: outputData.string,
                    error: errorData.string))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: CommandResult(status: -1, output: "", error: error.localizedDescription))
            }
        }
    }
}

private final class DataCollector: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
