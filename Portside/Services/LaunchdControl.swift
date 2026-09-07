import Darwin
import Foundation

/// User-domain LaunchAgents (`gui/<uid>/…`). KeepAlive jobs come back after
/// SIGTERM unless we boot them out of launchd first.
enum LaunchdControl {
    static func bootoutUserJobs(covering pids: [Int32]) {
        let targets = Set(pids.filter { $0 > 1 })
        guard !targets.isEmpty, let text = list() else { return }
        let uid = getuid()
        for line in text.split(whereSeparator: \.isNewline) {
            let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard cols.count >= 3, let pid = Int32(cols[0]), targets.contains(pid) else { continue }
            let label = String(cols[2])
            guard isUserJob(label) else { continue }
            _ = run(["bootout", "gui/\(uid)/\(label)"])
        }
    }

    private static func isUserJob(_ label: String) -> Bool {
        if label.isEmpty { return false }
        if label.hasPrefix("com.apple.") || label.hasPrefix("com.openssh.") { return false }
        if Policy.isProtectedName(label) { return false }
        return true
    }

    private static func list() -> String? {
        run(["list"])?.stdout
    }

    private static func run(_ arguments: [String]) -> ShellResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: data, as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
