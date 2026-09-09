import Foundation
import Observation

/// Owns the LAN listener and the list of other Macs.
@MainActor
@Observable
final class RemoteHub {
    private(set) var peers: [RemotePeer] = []
    private(set) var sharing = false
    private(set) var lastError: String?

    @ObservationIgnored private var server: RemoteServer?
    @ObservationIgnored private var poll: Task<Void, Never>?

    func setSharing(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    func refreshPeers() async {
        guard sharing, let pin = RemotePIN.load() else {
            peers = []
            return
        }
        peers = await RemoteClient.discover(pin: pin)
    }

    func stop(peer: RemotePeer, port: Int, confirmLAN: Bool) async throws {
        guard let pin = RemotePIN.load() else { throw PortkeepError.message("Set a PIN in Settings → Devices.") }
        try await RemoteClient.stop(peer: peer, port: port, pin: pin, confirmLAN: confirmLAN)
        await refreshPeers()
    }

    private func start() {
        stop()
        let pin = RemotePIN.ensure()
        do {
            let server = RemoteServer(pin: pin)
            try server.start()
            self.server = server
            sharing = true
            lastError = nil
            poll = Task { [weak self] in
                while let self, !Task.isCancelled {
                    await self.refreshPeers()
                    try? await Task.sleep(for: .seconds(8))
                }
            }
        } catch {
            lastError = error.localizedDescription
            sharing = false
        }
    }

    private func stop() {
        poll?.cancel()
        poll = nil
        server?.stop()
        server = nil
        sharing = false
        peers = []
    }
}
