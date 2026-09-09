import Foundation
import Network

enum RemoteClient {
    static func discover(pin: String, timeout: TimeInterval = 2.5) async -> [RemotePeer] {
        let endpoints = await browse(timeout: timeout)
        let token = RemoteLink.token(for: pin)
        let mine = DeviceIdentity.uuid
        var peers: [RemotePeer] = []
        await withTaskGroup(of: RemotePeer?.self) { group in
            for endpoint in endpoints {
                group.addTask { await fetch(endpoint: endpoint, token: token, mine: mine) }
            }
            for await peer in group {
                if let peer { peers.append(peer) }
            }
        }
        return peers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func stop(peer: RemotePeer, port: Int, pin: String, confirmLAN: Bool) async throws {
        guard let url = URL(string: "http://\(peer.endpoint)/v1/stop") else {
            throw PortkeepError.message("Bad peer address.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue(RemoteLink.token(for: pin), forHTTPHeaderField: RemoteLink.tokenHeader)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "port": port,
            "confirm_lan": confirmLAN,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 { return }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        throw PortkeepError.message(object?["error"] as? String ?? "Remote stop failed (\(code)).")
    }

    private static func fetch(endpoint: String, token: String, mine: String) async -> RemotePeer? {
        guard let url = URL(string: "http://\(endpoint)/v1/snapshot") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue(token, forHTTPHeaderField: RemoteLink.tokenHeader)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return RemotePeer(deviceID: endpoint, name: endpoint, host: endpoint, endpoint: endpoint, snapshot: nil, lastError: "Wrong PIN or refused.")
            }
            let snap = try JSONDecoder().decode(RemoteSnapshotDTO.self, from: data)
            if snap.deviceID == mine { return nil }
            return RemotePeer(deviceID: snap.deviceID, name: snap.name, host: snap.host, endpoint: endpoint, snapshot: snap, lastError: nil)
        } catch {
            return nil
        }
    }

    private static func browse(timeout: TimeInterval) async -> [String] {
        await withCheckedContinuation { continuation in
            let descriptor = NWBrowser.Descriptor.bonjour(type: RemoteLink.serviceType, domain: "local.")
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let browser = NWBrowser(for: descriptor, using: parameters)
            let box = BrowseBox(continuation: continuation)
            browser.browseResultsChangedHandler = { results, _ in
                box.results = results.compactMap(Self.address(from:))
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { box.finish([]) }
            }
            browser.start(queue: .global(qos: .userInitiated))
            box.browser = browser
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.finish(box.results)
            }
        }
    }

    private static func address(from result: NWBrowser.Result) -> String? {
        if case .bonjour(let record) = result.metadata, let host = record["host"], !host.isEmpty {
            return "\(host):\(RemoteLink.port)"
        }
        switch result.endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        case .service(let name, _, let domain, _):
            let host = name.replacingOccurrences(of: " ", with: "-")
            let suffix = domain.isEmpty ? "local." : domain
            return "\(host).\(suffix.hasSuffix(".") ? String(suffix.dropLast()) : suffix):\(RemoteLink.port)"
        default:
            return nil
        }
    }
}

private final class BrowseBox: @unchecked Sendable {
    var browser: NWBrowser?
    var results: [String] = []
    private var continuation: CheckedContinuation<[String], Never>?
    private let lock = NSLock()

    init(continuation: CheckedContinuation<[String], Never>) {
        self.continuation = continuation
    }

    func finish(_ values: [String]) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        browser?.cancel()
        cont?.resume(returning: Array(Set(values)))
    }
}
