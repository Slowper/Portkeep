import Foundation

enum LicenseKind: Equatable, Sendable {
    case personal
    case organization(org: String, seats: Int)
}

struct ParsedLicense: Equatable, Sendable {
    var key: String
    var kind: LicenseKind

    var org: String? {
        if case .organization(let org, _) = kind { return org }
        return nil
    }

    var seats: Int? {
        if case .organization(_, let seats) = kind { return seats }
        return nil
    }
}

enum LicenseKey {
    static func parse(_ raw: String) throws -> ParsedLicense {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let parts = key.split(separator: "-").map(String.init)
        if parts.count == 4, parts[0] == "PKP", parts.dropFirst().allSatisfy({ $0.count == 5 && $0.isAlphanumeric }) {
            return ParsedLicense(key: key, kind: .personal)
        }
        if parts.count == 5, parts[0] == "PKO",
           (2...12).contains(parts[1].count), parts[1].isAlphanumeric,
           let seats = Int(parts[2]), seats >= 1, seats <= 9999,
           parts[3].count == 5, parts[3].isAlphanumeric,
           parts[4].count == 5, parts[4].isAlphanumeric {
            return ParsedLicense(key: key, kind: .organization(org: parts[1], seats: seats))
        }
        throw LicenseError.malformed
    }
}

private extension String {
    var isAlphanumeric: Bool {
        !isEmpty && allSatisfy { $0.isLetter || $0.isNumber }
    }
}

enum LicenseError: LocalizedError {
    case malformed
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .malformed:
            "That doesn't look like a Portkeep key. Personal: PKP-XXXXX-XXXXX-XXXXX. Org: PKO-ACME-10-XXXXX-XXXXX."
        case .rejected(let reason): reason
        }
    }
}
