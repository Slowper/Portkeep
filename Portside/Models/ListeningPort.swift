import Foundation

struct ListeningPort: Identifiable, Hashable, Sendable {
    let pid: Int32
    let command: String
    let port: Int
    /// Bound addresses, e.g. "127.0.0.1", "*", "[::1]". A server that listens
    /// on both IPv4 and IPv6 shows up once with two addresses.
    let addresses: [String]

    var id: String { "\(pid):\(port)" }

    var isLocalOnly: Bool { Self.isLoopback(addresses) }

    /// Ports published by Docker Desktop / OrbStack show up under their VM
    /// helper process rather than the container itself.
    var isDockerProxy: Bool {
        let lower = command.lowercased()
        return lower.hasPrefix("com.docker") || lower.hasPrefix("orbstack") || lower.hasPrefix("vpnkit")
    }

    var url: URL? { URL(string: "http://localhost:\(port)") }
}
