import Foundation

struct DockerContainer: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let image: String
    /// Docker's machine state: running, exited, paused, created, restarting...
    let state: String
    /// Human status, e.g. "Up 2 hours" or "Exited (0) 3 days ago".
    let status: String
    /// Raw port mapping string, e.g. "0.0.0.0:5432->5432/tcp, :::5432->5432/tcp".
    let ports: String

    var isRunning: Bool { state == "running" }
    var isPaused: Bool { state == "paused" }
    var shortID: String { String(id.prefix(12)) }

    /// Host ports this container publishes.
    var publishedPorts: [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for match in ports.matches(of: #/:(\d+)->/#) {
            if let port = Int(match.output.1), seen.insert(port).inserted {
                result.append(port)
            }
        }
        return result.sorted()
    }
}

enum DockerAvailability: Equatable, Sendable {
    case unknown
    case available
    case notInstalled
    case daemonNotRunning
    case failed(String)
}

enum DockerAction: String, Sendable {
    case start, stop, restart
}
