import Foundation
import Observation

/// Trial + license-key gating.
///
/// Portside is distributed outside the Mac App Store (it needs to inspect other
/// processes, which the sandbox forbids), so StoreKit isn't an option. The
/// intended production flow is: sell through Paddle / LemonSqueezy / Setapp,
/// issue a key, and validate it against your backend in `validate(key:)`.
///
/// What's here is the complete local half of that flow: trial tracking,
/// activation UI plumbing, persistence, and the `isPro` gate the UI reads.
@MainActor
@Observable
final class LicenseManager {
    enum Status: Equatable, Sendable {
        case trial(daysLeft: Int)
        case expired
        case licensed(key: String)
    }

    static let trialLengthDays = 14
    static let purchaseURL = URL(string: "https://portside.app/buy")!  // TODO: real checkout link

    private(set) var status: Status = .expired
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Keys.trialStartedAt) == nil {
            defaults.set(Date(), forKey: Keys.trialStartedAt)
        }
        refresh()
    }

    /// Everything gated behind Pro is available during the trial.
    var isPro: Bool {
        if case .expired = status { return false }
        return true
    }

    var isLicensed: Bool {
        if case .licensed = status { return true }
        return false
    }

    func refresh() {
        if let key = defaults.string(forKey: Keys.licenseKey), !key.isEmpty {
            status = .licensed(key: key)
            return
        }
        let started = defaults.object(forKey: Keys.trialStartedAt) as? Date ?? Date()
        let elapsed = Calendar.current.dateComponents([.day], from: started, to: Date()).day ?? 0
        let left = Self.trialLengthDays - elapsed
        status = left > 0 ? .trial(daysLeft: left) : .expired
    }

    func activate(key rawKey: String) async throws {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        try await validate(key: key)
        // TODO: move to Keychain before shipping; UserDefaults is trivially editable.
        defaults.set(key, forKey: Keys.licenseKey)
        refresh()
    }

    func deactivate() {
        defaults.removeObject(forKey: Keys.licenseKey)
        refresh()
    }

    // MARK: - Validation

    /// Format: PSD-XXXXX-XXXXX-XXXXX (letters/digits).
    private static let keyPattern = #/^PSD-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}$/#

    private func validate(key: String) async throws {
        guard key.wholeMatch(of: Self.keyPattern) != nil else {
            throw LicenseError.malformed
        }
        // TODO: POST the key + a device identifier to your licensing backend
        // (e.g. a Supabase Edge Function) and throw `.rejected` on failure.
        // Until that exists, any well-formed key activates locally.
    }

    private enum Keys {
        static let trialStartedAt = "license.trialStartedAt"
        static let licenseKey = "license.key"
    }
}

enum LicenseError: LocalizedError {
    case malformed
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .malformed: "That doesn't look like a Portside key. Keys look like PSD-XXXXX-XXXXX-XXXXX."
        case .rejected(let reason): reason
        }
    }
}
