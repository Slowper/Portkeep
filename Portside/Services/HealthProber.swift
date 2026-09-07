import Foundation

struct ProbeResult: Sendable, Hashable {
    enum Kind: Hashable, Sendable {
        /// Spoke HTTP and answered with this status code.
        case http(Int)
        /// Accepted the connection but isn't HTTP (databases, gRPC, sockets...).
        case tcp
        /// Nothing answered.
        case unreachable
    }

    let kind: Kind
    let latencyMs: Int
    let checkedAt: Date
}

/// Knocks on each listening port so the UI can show "200 · 12ms" instead of
/// just "something is here". Results are cached and refreshed lazily.
actor HealthProber {
    private var cache: [Int: ProbeResult] = [:]
    private var inFlight: Set<Int> = []
    private let staleAfter: TimeInterval = 8
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2.5
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: config)
    }

    /// Returns cached results immediately and refreshes anything stale in the
    /// background. Call again on the next tick to pick up fresh values.
    func results(for ports: [Int]) -> [Int: ProbeResult] {
        let now = Date()
        for port in ports {
            let stale = cache[port].map { now.timeIntervalSince($0.checkedAt) > staleAfter } ?? true
            if stale, !inFlight.contains(port) {
                inFlight.insert(port)
                Task { await self.probe(port) }
            }
        }
        // Drop ports that went away so the cache doesn't grow forever.
        let live = Set(ports)
        cache = cache.filter { live.contains($0.key) }
        return cache
    }

    private func probe(_ port: Int) async {
        defer { inFlight.remove(port) }
        guard let url = URL(string: "http://localhost:\(port)/") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Portkeep/1.0 (+health)", forHTTPHeaderField: "User-Agent")

        let start = DispatchTime.now()
        let kind: ProbeResult.Kind
        do {
            let (_, response) = try await session.data(for: request)
            kind = (response as? HTTPURLResponse).map { .http($0.statusCode) } ?? .tcp
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                kind = .unreachable
            default:
                // Timed out / connection reset / bad response: something is
                // listening but it doesn't speak HTTP (or is very slow).
                kind = .tcp
            }
        } catch {
            kind = .tcp
        }
        let elapsed = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        cache[port] = ProbeResult(kind: kind, latencyMs: elapsed, checkedAt: Date())
    }
}
