import Foundation
import IOKit

struct OrgSeat: Equatable, Sendable, Codable {
    var org: String
    var seats: Int
    var deviceID: String
    var host: String
    var user: String
    var activatedAt: Date
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

enum OrgClaim {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(PortAllocator.directoryName, isDirectory: true)
            .appendingPathComponent("org.json")
    }

    static func load() -> OrgSeat? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OrgSeat.self, from: data)
    }

    static func save(_ seat: OrgSeat) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(seat).write(to: url, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    static func claim(org: String, seats: Int) throws -> OrgSeat {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let seat = OrgSeat(
            org: org,
            seats: seats,
            deviceID: DeviceIdentity.uuid,
            host: ProcessInfo.processInfo.hostName,
            user: NSUserName(),
            activatedAt: Date()
        )
        try save(seat)
        return seat
    }
}
