import Foundation

/// Lists every TCP socket in LISTEN state using `lsof`, which ships with macOS.
enum PortScanner {
    static let lsofPath = "/usr/sbin/lsof"

    static func scan() async throws -> [ListeningPort] {
        // -F pcn: machine-readable output with (p)id, (c)ommand and (n)ame fields.
        // +c 0: don't truncate command names to the default 9 columns.
        let result = try await ShellRunner.run(
            lsofPath,
            ["-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]
        )
        // lsof exits 1 when nothing matched; that's an empty list, not an error.
        return parse(result.stdout)
    }

    static func parse(_ output: String) -> [ListeningPort] {
        struct Accumulator {
            var command = ""
            var addresses: [String] = []
        }

        var byKey: [String: Accumulator] = [:]
        var order: [String] = []
        var currentPID: Int32 = 0
        var currentCommand = ""

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let field = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())
            switch field {
            case "p":
                currentPID = Int32(value) ?? 0
            case "c":
                currentCommand = value
            case "n":
                guard let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                let address = String(value[..<colon])
                let key = "\(currentPID):\(port)"
                if byKey[key] == nil {
                    byKey[key] = Accumulator(command: currentCommand)
                    order.append(key)
                }
                if byKey[key]?.addresses.contains(address) == false {
                    byKey[key]?.addresses.append(address)
                }
            default:
                continue
            }
        }

        return order.compactMap { key -> ListeningPort? in
            guard let acc = byKey[key] else { return nil }
            let parts = key.split(separator: ":")
            guard parts.count == 2, let pid = Int32(parts[0]), let port = Int(parts[1]) else { return nil }
            return ListeningPort(pid: pid, command: acc.command, port: port, addresses: acc.addresses)
        }
        .sorted { $0.port < $1.port }
    }
}
