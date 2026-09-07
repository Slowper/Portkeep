import Foundation

/// MDM / defaults domain is the app bundle id: `com.sajidpalagiri.portkeep`.
enum PolicyKey {
    static let enabled = "PolicyEnabled"
    static let protectedNames = "PolicyProtectedNames"
    static let allowedRoots = "PolicyAllowedRoots"
    static let allowOutsideHome = "PolicyAllowOutsideHome"
    static let requireLANConfirm = "PolicyRequireLANConfirm"
    static let allowProtectedStop = "PolicyAllowProtectedStop"
}

struct PolicyConfig: Sendable, Equatable {
    var enabled: Bool
    var extraProtectedNames: [String]
    var allowedRoots: [String]
    var allowOutsideHome: Bool
    var requireLANConfirm: Bool
    var allowProtectedStop: Bool

    var protectedNames: Set<String> {
        Policy.defaultProtectedNames.union(extraProtectedNames.map { $0.lowercased() })
    }

    var roots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ([home] + allowedRoots)
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { !$0.isEmpty }
    }

    static func load(from defaults: UserDefaults = PortkeepDefaults.suite) -> PolicyConfig {
        PolicyConfig(
            enabled: defaults.object(forKey: PolicyKey.enabled) as? Bool ?? true,
            extraProtectedNames: defaults.stringArray(forKey: PolicyKey.protectedNames) ?? [],
            allowedRoots: defaults.stringArray(forKey: PolicyKey.allowedRoots) ?? [],
            allowOutsideHome: defaults.bool(forKey: PolicyKey.allowOutsideHome),
            requireLANConfirm: defaults.object(forKey: PolicyKey.requireLANConfirm) as? Bool ?? true,
            allowProtectedStop: defaults.bool(forKey: PolicyKey.allowProtectedStop)
        )
    }
}

enum PolicyVerdict: Equatable, Sendable {
    case allow
    case confirm(String)
    case deny(String)

    var isDenied: Bool {
        if case .deny = self { return true }
        return false
    }

    var needsConfirm: Bool {
        if case .confirm = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .allow: nil
        case .confirm(let text), .deny(let text): text
        }
    }
}

enum Policy {
    /// Long-running infrastructure. A tree kill must never include these.
    static let defaultProtectedNames: Set<String> = [
        "ollama", "postgres", "postmaster", "mysqld", "mariadbd", "redis-server", "mongod", "memcached",
        "nginx", "httpd", "caddy", "traefik", "docker", "dockerd", "com.docker.backend", "colima", "limactl",
        "qemu-system-aarch64", "tailscaled", "syncthing", "plex media server", "sshd", "cupsd",
        "influxd", "clickhouse", "elasticsearch", "rabbitmq", "kafka", "zookeeper", "minio", "vault",
        "consul", "nats-server", "etcd", "lmstudio", "lm studio", "llama-server", "koboldcpp", "jan",
    ]

    static func isProtectedName(_ raw: String) -> Bool {
        let name = (raw as NSString).lastPathComponent.lowercased()
        if defaultProtectedNames.contains(name) { return true }
        return defaultProtectedNames.contains(where: { name.hasPrefix($0) })
    }

    static func evaluate(
        command: String,
        executable: String?,
        cwd: String?,
        addresses: [String],
        origin: ProcessOrigin?,
        extraCommands: [String] = [],
        config: PolicyConfig = .load()
    ) -> PolicyVerdict {
        guard config.enabled else { return .allow }

        let names = ([command] + extraCommands + [executable].compactMap { $0 }).map {
            ($0 as NSString).lastPathComponent.lowercased()
        }
        if let hit = names.first(where: { config.protectedNames.contains($0) || isProtectedName($0) }) {
            let reason = "Protected: \(hit) is infrastructure. Policy will not stop it."
            return config.allowProtectedStop ? .confirm(reason) : .deny(reason)
        }
        if origin == .service {
            let reason = "Protected: this looks like a LaunchAgent / Homebrew service."
            return config.allowProtectedStop ? .confirm(reason) : .deny(reason)
        }
        if AppSettings.isSystemProcess(command) {
            return .deny("Protected: \(command) is a macOS system process.")
        }

        let knownLocation = (cwd != nil && cwd != "/") || !(executable ?? "").isEmpty
        let trusted = origin == .orphaned || origin?.isAgent == true
        if !config.allowOutsideHome, knownLocation, !trusted,
           !isInsideAllowedRoots(cwd: cwd, executable: executable, roots: config.roots) {
            return .deny("Outside allowed folders. Stops are limited to your home directory and MDM-allowed roots.")
        }

        let lan = !addresses.isEmpty && !ListeningPort.isLoopback(addresses)
        if config.requireLANConfirm, lan {
            return .confirm("Bound on the LAN (\(addresses.joined(separator: ", "))). Confirm you want to stop it.")
        }
        return .allow
    }

    static func evaluateDocker(name: String, ports: String, config: PolicyConfig = .load()) -> PolicyVerdict {
        guard config.enabled else { return .allow }
        let lower = name.lowercased()
        if config.protectedNames.contains(lower) || isProtectedName(lower) {
            let reason = "Protected: container \(name) is on the deny list."
            return config.allowProtectedStop ? .confirm(reason) : .deny(reason)
        }
        let lan = ports.contains("0.0.0.0") || ports.contains(":::") || ports.contains("*")
        if config.requireLANConfirm, lan {
            return .confirm("Container \(name) publishes on all interfaces. Confirm you want to stop it.")
        }
        return .allow
    }

    private static func isInsideAllowedRoots(cwd: String?, executable: String?, roots: [String]) -> Bool {
        let homebrew = ["/opt/homebrew/", "/usr/local/", "/opt/local/"]
        func allowed(_ raw: String?) -> Bool {
            guard let raw, !raw.isEmpty, raw != "/" else { return false }
            let path = URL(fileURLWithPath: raw).standardizedFileURL.path
            if roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
            // Installed runtimes (node, python) are fine when the working directory is a project.
            if homebrew.contains(where: { path.hasPrefix($0) }), let cwd, allowed(cwd) { return true }
            return false
        }
        if allowed(cwd) { return true }
        if allowed(executable) { return true }
        // Leftovers whose cwd was deleted still belong to the user if the binary is under $HOME.
        if let executable, roots.contains(where: { executable.hasPrefix($0 + "/") || executable.hasPrefix($0) }) {
            return true
        }
        return false
    }
}

extension ListeningPort {
    static func isLoopback(_ addresses: [String]) -> Bool {
        addresses.allSatisfy { address in
            address == "127.0.0.1" || address == "[::1]" || address == "localhost"
                || address.hasPrefix("127.")
        }
    }
}
