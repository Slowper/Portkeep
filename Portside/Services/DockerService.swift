import Foundation

enum DockerService {
    struct Snapshot: Sendable {
        let availability: DockerAvailability
        let containers: [DockerContainer]
    }

    /// One JSON object per line from `docker ps --format '{{json .}}'`.
    private struct PSLine: Decodable {
        let ID: String
        let Names: String
        let Image: String
        let State: String
        let Status: String
        let Ports: String
    }

    static func executable() -> String? {
        ShellRunner.resolve("docker")
    }

    static func snapshot() async -> Snapshot {
        guard let docker = executable() else {
            return Snapshot(availability: .notInstalled, containers: [])
        }

        let result: ShellResult
        do {
            result = try await ShellRunner.run(docker, ["ps", "-a", "--no-trunc", "--format", "{{json .}}"], timeout: 8)
        } catch {
            return Snapshot(availability: .failed(error.localizedDescription), containers: [])
        }

        guard result.succeeded else {
            let stderr = result.stderr.lowercased()
            let daemonDownMarkers = [
                "cannot connect to the docker daemon",
                "failed to connect to the docker api",
                "daemon is running",
                "docker.sock",
                "connection refused",
            ]
            if daemonDownMarkers.contains(where: stderr.contains) {
                return Snapshot(availability: .daemonNotRunning, containers: [])
            }
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return Snapshot(availability: .failed(message.isEmpty ? "docker ps failed" : message), containers: [])
        }

        let decoder = JSONDecoder()
        let containers = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> DockerContainer? in
                guard let data = line.data(using: .utf8),
                      let ps = try? decoder.decode(PSLine.self, from: data) else { return nil }
                return DockerContainer(
                    id: ps.ID,
                    name: ps.Names,
                    image: ps.Image,
                    state: ps.State,
                    status: ps.Status,
                    ports: ps.Ports
                )
            }
            .sorted { lhs, rhs in
                if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

        return Snapshot(availability: .available, containers: containers)
    }

    static func perform(_ action: DockerAction, on container: DockerContainer) async throws {
        guard let docker = executable() else { throw ShellError.toolNotFound("docker") }
        let result = try await ShellRunner.run(docker, [action.rawValue, container.id], timeout: 30)
        guard result.succeeded else {
            throw DockerError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

enum DockerError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message.isEmpty ? "Docker command failed." : message
        }
    }
}
