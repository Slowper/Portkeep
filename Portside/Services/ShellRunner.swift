import Foundation

struct ShellResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

enum ShellError: LocalizedError {
    case launchFailed(String)
    case toolNotFound(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message): "Could not launch process: \(message)"
        case .toolNotFound(let tool): "\(tool) was not found on this machine."
        case .timedOut(let tool): "\(tool) did not respond in time."
        }
    }
}

/// Runs command-line tools from a GUI app. GUI apps get a minimal PATH, so we
/// resolve executables against the places dev tools usually live.
enum ShellRunner {
    static let searchDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "~/.docker/bin",
        "~/.orbstack/bin",
        "~/.rd/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    private static var expandedSearchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return searchDirectories.map { $0.replacingOccurrences(of: "~", with: home) }
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"].map { [$0] } ?? []
        env["PATH"] = (expandedSearchDirectories + existing).joined(separator: ":")
        return env
    }

    /// Finds an executable by name in the search directories.
    static func resolve(_ tool: String) -> String? {
        let fm = FileManager.default
        for dir in expandedSearchDirectories {
            let candidate = (dir as NSString).appendingPathComponent(tool)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 15
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ShellError.launchFailed(error.localizedDescription))
                    return
                }

                let timedOut = AtomicFlag()
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        timedOut.set()
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                // Drain both pipes concurrently so a chatty tool can't deadlock
                // on a full pipe buffer before it exits.
                let stderrBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                watchdog.cancel()

                if timedOut.isSet {
                    continuation.resume(throwing: ShellError.timedOut(executable))
                    return
                }

                continuation.resume(returning: ShellResult(
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrBox.data, as: UTF8.self)
                ))
            }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
