import Foundation
import IslandProtocol

/// Tracks blocking gate requests awaiting a human (or rule) decision, keyed by
/// the gate envelope's id. Responding writes the answer back on the shim's own
/// connection and forgets it.
@MainActor
public final class GateCenter {
    private struct PendingGate {
        let connection: SocketConnection
        let groupID: UUID
    }

    private var pending: [UUID: PendingGate] = [:]

    /// Called when a shim disconnects before being answered (agent was killed,
    /// or its hook timeout expired) so the UI can drop the card.
    public var onGateAborted: ((UUID) -> Void)?

    public init() {}

    public func register(id: UUID, connection: SocketConnection, groupID: UUID? = nil) {
        let groupID = groupID ?? id
        pending[id] = PendingGate(connection: connection, groupID: groupID)
        connection.addCloseHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.pending.removeValue(forKey: id) != nil else { return }
                guard !self.pending.values.contains(where: { $0.groupID == groupID }) else { return }
                self.onGateAborted?(groupID)
            }
        }
    }

    public func respond(id: UUID, _ response: GateResponse) {
        let groupID = pending[id]?.groupID ?? id
        let grouped = pending.filter { $0.value.groupID == groupID }
        guard !grouped.isEmpty else { return }
        for (gateID, gate) in grouped {
            pending.removeValue(forKey: gateID)
            if let line = try? WireCodec.encodeLine(Envelope(id: gateID, type: .gateResponse, body: response)) {
                gate.connection.sendLine(line)
            }
            gate.connection.close()
        }
    }

    public var pendingIDs: [UUID] { Array(pending.keys) }
}
