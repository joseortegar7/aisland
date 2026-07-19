import Foundation
import IslandProtocol

/// Tracks blocking gate requests awaiting a human (or rule) decision, keyed by
/// the gate envelope's id. Responding writes the answer back on the shim's own
/// connection and forgets it.
@MainActor
public final class GateCenter {
    private var pending: [UUID: SocketConnection] = [:]

    /// Called when a shim disconnects before being answered (agent was killed,
    /// or its hook timeout expired) so the UI can drop the card.
    public var onGateAborted: ((UUID) -> Void)?

    public init() {}

    public func register(id: UUID, connection: SocketConnection) {
        pending[id] = connection
        connection.onClosed = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.pending.removeValue(forKey: id) != nil else { return }
                self.onGateAborted?(id)
            }
        }
    }

    public func respond(id: UUID, _ response: GateResponse) {
        guard let connection = pending.removeValue(forKey: id) else { return }
        if let line = try? WireCodec.encodeLine(Envelope(id: id, type: .gateResponse, body: response)) {
            connection.sendLine(line)
        }
        connection.close()
    }

    public var pendingIDs: [UUID] { Array(pending.keys) }
}
