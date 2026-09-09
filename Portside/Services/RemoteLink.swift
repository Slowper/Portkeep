import CryptoKit
import Foundation
import IOKit
import Security

enum PortkeepError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let reason): reason
        }
    }
}

enum DeviceIdentity {
    static var uuid: String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return fallback }
        defer { IOObjectRelease(service) }
        guard let cf = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0) else {
            return fallback
        }
        return (cf.takeRetainedValue() as? String) ?? fallback
    }

    static var fallback: String {
        "\(NSUserName())@\(ProcessInfo.processInfo.hostName)"
    }
}

enum RemoteLink {
    static let serviceType = "_portkeep._tcp"
    static let port: UInt16 = 17373
    static let tokenHeader = "X-Portkeep-Token"

    static func token(for pin: String) -> String {
        let digest = SHA256.hash(data: Data("portkeep-v1:\(pin)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static var displayName: String {
        Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
    }
}

struct RemoteListenerDTO: Codable, Sendable, Identifiable, Hashable {
    var port: Int
    var command: String
    var project: String?
    var path: String?
    var origin: String?
    var leftBehind: Bool
    var lan: Bool

    var id: String { "\(port)-\(command)" }
}

struct RemoteSnapshotDTO: Codable, Sendable, Hashable {
    var deviceID: String
    var name: String
    var host: String
    var user: String
    var leftovers: [RemoteListenerDTO]
    var listeners: [RemoteListenerDTO]

    static func current() async -> RemoteSnapshotDTO {
        let snapshot = try? await RuntimeSnapshot.capture()
        let rows: [RemoteListenerDTO] = (snapshot?.records ?? []).map { record in
            RemoteListenerDTO(
                port: record.port.port,
                command: record.lineage?.rootCommand ?? record.port.command,
                project: record.project?.name,
                path: record.project?.directory.path,
                origin: record.lineage?.origin.label,
                leftBehind: record.lineage?.isLeftBehind ?? false,
                lan: !record.port.isLocalOnly
            )
        }
        return RemoteSnapshotDTO(
            deviceID: DeviceIdentity.uuid,
            name: RemoteLink.displayName,
            host: ProcessInfo.processInfo.hostName,
            user: NSUserName(),
            leftovers: rows.filter(\.leftBehind),
            listeners: rows
        )
    }
}

struct RemotePeer: Identifiable, Sendable, Hashable {
    var id: String { deviceID }
    var deviceID: String
    var name: String
    var host: String
    var endpoint: String
    var snapshot: RemoteSnapshotDTO?
    var lastError: String?

    var leftoverCount: Int { snapshot?.leftovers.count ?? 0 }
}

enum RemotePIN {
    private static let account = "remote-pin"

    static func load() -> String? {
        read()
    }

    @discardableResult
    static func ensure() -> String {
        if let existing = read(), existing.count == 6 { return existing }
        let generated = String(Int.random(in: 100_000...999_999))
        save(generated)
        return generated
    }

    static func replace() -> String {
        let generated = String(Int.random(in: 100_000...999_999))
        save(generated)
        return generated
    }

    private static func save(_ pin: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PortkeepDefaults.domain,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(pin.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PortkeepDefaults.domain,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let pin = String(data: data, encoding: .utf8),
              !pin.isEmpty
        else { return nil }
        return pin
    }
}
