import Darwin
import Foundation

enum PortAllocatorError: LocalizedError, Sendable {
    case invalidName
    case invalidPort
    case noFreePort(ClosedRange<Int>)
    case notFound
    case io(String)

    var errorDescription: String? {
        switch self {
        case .invalidName: "Service name must be letters, numbers, dots or hyphens."
        case .invalidPort: "Port must be between 1 and 65535."
        case .noFreePort(let range): "No free port in \(range.lowerBound)–\(range.upperBound)."
        case .notFound: "No lease matches."
        case .io(let message): message
        }
    }
}

/// File-locked registry of reserved ports. Same worktree + service name always
/// gets the same port back, unless something else is now sitting on it.
enum PortAllocator {
    static let defaultRange: ClosedRange<Int> = 3000...4999
    static let directoryName = ".portkeep"
    static let legacyDirectoryName = ".portside"
    static let storeName = "leases.json"

    static var storeURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let current = home
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(storeName)
        if FileManager.default.fileExists(atPath: current.path) {
            return current
        }
        let legacy = home
            .appendingPathComponent(legacyDirectoryName, isDirectory: true)
            .appendingPathComponent(storeName)
        if FileManager.default.fileExists(atPath: legacy.path) {
            migrateLegacyStore(from: legacy, to: current)
            return current
        }
        return current
    }

    private static func migrateLegacyStore(from legacy: URL, to current: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: legacy, to: current)
    }

    static func normalizeName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }

    static func allLeases() throws -> [PortLease] {
        try mutate { $0.leases }
    }

    static func leases(in directory: String) throws -> [PortLease] {
        let path = URL(fileURLWithPath: directory).standardizedFileURL.path
        return try allLeases().filter { $0.directory == path }
    }

    static func lease(forPort port: Int) throws -> PortLease? {
        try allLeases().first { $0.port == port }
    }

    /// Returns the existing lease or creates one. Preferred port wins when free;
    /// otherwise a deterministic pick from `range`, walking upward on collision.
    static func allocate(
        name rawName: String,
        at path: String,
        preferred: Int? = nil,
        range: ClosedRange<Int> = defaultRange,
        taken: Set<Int>
    ) async throws -> PortLease {
        guard let name = normalizeName(rawName) else { throw PortAllocatorError.invalidName }
        if let preferred, !(1...65535).contains(preferred) { throw PortAllocatorError.invalidPort }

        let identity = await WorkspaceIdentity.detect(at: path)
        let key = identity.leaseKey(name: name)
        let now = Date()

        let lease = try mutate { store in
            pruneStale(&store, taken: taken, now: now)
            if var existing = store.leases.first(where: { $0.id == key }) {
                let holder = taken.contains(existing.port)
                let ours = holder && existing.directory == identity.directory
                if !holder || ours {
                    existing.lastUsedAt = now
                    existing.branch = identity.branch ?? existing.branch
                    upsert(&store, existing)
                    return existing
                }
                // Our reserved port was stolen. Keep the name, pick a new number.
            }

            let pick = preferred
                ?? (identity.worktreeName == nil ? wellKnownPort(for: name) : nil)
                ?? deterministicPort(for: key, in: range)
            guard let port = firstFree(from: pick, range: range, taken: taken, reserved: Set(store.leases.map(\.port))) else {
                throw PortAllocatorError.noFreePort(range)
            }

            let created = PortLease(
                name: name,
                port: port,
                directory: identity.directory,
                repoRoot: identity.repoRoot,
                worktreeName: identity.worktreeName,
                projectName: identity.projectName,
                branch: identity.branch,
                createdAt: now,
                lastUsedAt: now
            )
            upsert(&store, created)
            return created
        }
        Audit.record(
            action: "alloc",
            port: lease.port,
            command: lease.name,
            project: lease.projectName,
            path: lease.directory
        )
        return lease
    }

    static func release(name rawName: String?, port: Int?, at path: String?) throws -> PortLease {
        let directory = path.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let name = rawName.flatMap(normalizeName)
        return try mutate { store in
            guard let index = store.leases.firstIndex(where: { lease in
                if let port { return lease.port == port }
                if let name, let directory {
                    return lease.name == name && lease.directory == directory
                }
                if let name { return lease.name == name }
                return false
            }) else { throw PortAllocatorError.notFound }
            let lease = store.leases.remove(at: index)
            Audit.record(
                action: "release",
                port: lease.port,
                command: lease.name,
                project: lease.projectName,
                path: lease.directory
            )
            return lease
        }
    }

    // MARK: - Internals

    private static func wellKnownPort(for name: String) -> Int? {
        switch name {
        case "web", "app", "frontend", "next", "nuxt", "remix", "svelte": 3000
        case "vite", "dev": 5173
        case "storybook": 6006
        case "api", "backend", "server": 4000
        case "graphql": 4000
        case "docs": 3001
        default: nil
        }
    }

    private static func deterministicPort(for key: String, in range: ClosedRange<Int>) -> Int {
        var hash: UInt64 = 2_166_131_261
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 16_777_619
        }
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(hash % span)
    }

    private static func firstFree(from start: Int, range: ClosedRange<Int>, taken: Set<Int>, reserved: Set<Int>) -> Int? {
        let busy = taken.union(reserved)
        let clamped = min(max(start, range.lowerBound), range.upperBound)
        for port in clamped...range.upperBound where !busy.contains(port) { return port }
        for port in range.lowerBound..<clamped where !busy.contains(port) { return port }
        return nil
    }

    private static func upsert(_ store: inout LeaseStore, _ lease: PortLease) {
        if let index = store.leases.firstIndex(where: { $0.id == lease.id }) {
            store.leases[index] = lease
        } else {
            store.leases.append(lease)
        }
    }

    /// Drop leases whose folder is gone and whose port isn't in use, or that
    /// haven't been touched in a week and aren't listening.
    private static func pruneStale(_ store: inout LeaseStore, taken: Set<Int>, now: Date) {
        let week: TimeInterval = 7 * 24 * 60 * 60
        store.leases.removeAll { lease in
            if taken.contains(lease.port) { return false }
            let folderGone = !FileManager.default.fileExists(atPath: lease.directory)
            let old = now.timeIntervalSince(lease.lastUsedAt) > week
            return folderGone || old
        }
    }

    private static func mutate<T>(_ body: (inout LeaseStore) throws -> T) throws -> T {
        let url = storeURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data("{}".utf8))
        }

        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw PortAllocatorError.io("Couldn't open \(url.path)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw PortAllocatorError.io("Couldn't lock the lease file.") }
        defer { flock(fd, LOCK_UN) }

        let data = (try? Data(contentsOf: url)) ?? Data()
        var store = (try? JSONDecoder.iso8601.decode(LeaseStore.self, from: data)) ?? LeaseStore()
        let result = try body(&store)
        let encoder = JSONEncoder.iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(store).write(to: url, options: .atomic)
        return result
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
