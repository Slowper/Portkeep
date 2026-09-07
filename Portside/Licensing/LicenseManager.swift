import Foundation
import Observation

/// Trial, personal Pro (`PKP-`), and org seats (`PKO-`).
///
/// Sold outside the Mac App Store (the sandbox cannot inspect other processes).
/// Personal keys and org keys activate locally today; a licensing backend can
/// later reject a key or a seat that is already taken. MDM can force `OrgLicense`.
@MainActor
@Observable
final class LicenseManager {
    enum Status: Equatable, Sendable {
        case trial(daysLeft: Int)
        case expired
        case licensed(key: String)
        case organization(OrgSeat)
    }

    static let trialLengthDays = 14
    static let purchaseURL = Product.websiteURL

    private(set) var status: Status = .expired
    private let defaults: UserDefaults

    init(defaults: UserDefaults = PortkeepDefaults.suite) {
        self.defaults = defaults
        if defaults.object(forKey: Keys.trialStartedAt) == nil {
            defaults.set(Date(), forKey: Keys.trialStartedAt)
        }
        applyManagedOrgIfNeeded()
        refresh()
    }

    /// Everything gated behind Pro is available during the trial and on a seat.
    var isPro: Bool {
        if case .expired = status { return false }
        return true
    }

    var isLicensed: Bool {
        switch status {
        case .licensed, .organization: true
        default: false
        }
    }

    var isOrganization: Bool {
        if case .organization = status { return true }
        return false
    }

    var orgIsManaged: Bool {
        defaults.objectIsForced(forKey: ManagedKey.orgLicense)
    }

    func refresh() {
        if let key = LicenseStore.load(), let parsed = try? LicenseKey.parse(key) {
            switch parsed.kind {
            case .personal:
                status = .licensed(key: parsed.key)
            case .organization(let org, let seats):
                let claim = OrgClaim.load() ?? (try? OrgClaim.claim(org: org, seats: seats))
                if let claim {
                    status = .organization(claim)
                } else {
                    status = .licensed(key: parsed.key)
                }
            }
            return
        }
        let started = defaults.object(forKey: Keys.trialStartedAt) as? Date ?? Date()
        let elapsed = Calendar.current.dateComponents([.day], from: started, to: Date()).day ?? 0
        let left = Self.trialLengthDays - elapsed
        status = left > 0 ? .trial(daysLeft: left) : .expired
    }

    func activate(key rawKey: String) async throws {
        try apply(rawKey)
        refresh()
    }

    func deactivate() {
        guard !orgIsManaged else { return }
        LicenseStore.clear()
        OrgClaim.clear()
        Audit.record(action: "license_deactivate")
        refresh()
    }

    private func apply(_ rawKey: String) throws {
        let parsed = try LicenseKey.parse(rawKey)
        try LicenseStore.save(parsed.key)
        switch parsed.kind {
        case .personal:
            OrgClaim.clear()
            Audit.record(action: "license_activate", detail: "personal")
        case .organization(let org, let seats):
            let claim = try OrgClaim.claim(org: org, seats: seats)
            Audit.record(action: "license_activate", command: org, detail: "org \(seats) seats · \(claim.deviceID)")
        }
    }

    private func applyManagedOrgIfNeeded() {
        guard let key = defaults.string(forKey: ManagedKey.orgLicense), !key.isEmpty else { return }
        try? apply(key)
    }

    private enum Keys {
        static let trialStartedAt = "license.trialStartedAt"
    }
}
