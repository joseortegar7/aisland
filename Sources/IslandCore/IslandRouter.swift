import Foundation
import IslandProtocol

/// Central glue: socket lines in → session state + gates out. Runs on the
/// main actor; the socket server trampolines into it.
@MainActor
public final class IslandRouter {
    public let store: SessionStore
    public let gates: GateCenter
    public let rules: ApprovalRulesStore

    /// Fired when a gate starts waiting on the user (UI should auto-expand).
    public var onNeedsAttention: (() -> Void)?

    /// Overridable for tests; defaults to reading Claude's real settings.
    public var oracleProvider: @Sendable (String) -> PermissionOracle = { cwd in
        PermissionOracle.loadForProject(cwd: cwd)
    }

    public init(store: SessionStore, gates: GateCenter, rules: ApprovalRulesStore = ApprovalRulesStore()) {
        self.store = store
        self.gates = gates
        self.rules = rules
        gates.onGateAborted = { [weak self] id in
            self?.store.removeRequest(id: id)
        }
    }

    /// Entry point from SocketServer (called on the socket queue).
    public nonisolated func attach(to server: SocketServer) {
        server.onLine = { [weak self] line, connection in
            Task { @MainActor [weak self] in
                self?.handle(line: line, connection: connection)
            }
        }
    }

    public func handle(line: Data, connection: SocketConnection) {
        guard let header = try? WireCodec.decodeHeader(line) else { return }
        switch header.type {
        case .hookEvent:
            guard let envelope = try? WireCodec.decode(HookEvent.self, from: line) else { return }
            store.apply(envelope.body)
        case .gateRequest:
            guard let envelope = try? WireCodec.decode(HookEvent.self, from: line) else {
                // Malformed gate: answer "ask" so the shim never hangs.
                respond(id: header.id, connection: connection, decision: .ask)
                return
            }
            handleGate(envelope, connection: connection)
        case .ctlCommand:
            guard let envelope = try? WireCodec.decode(CtlCommand.self, from: line) else {
                connection.close()
                return
            }
            handleCtl(envelope, connection: connection)
        case .remoteHello:
            break // Phase 8.
        case .gateResponse:
            break // Server never receives these.
        }
    }

    private func handleGate(_ envelope: Envelope<HookEvent>, connection: SocketConnection) {
        let event = envelope.body
        store.apply(event)
        let sessionID = SessionID(agent: event.agent, raw: event.sessionID, host: event.host)

        guard let call = ClaudeCodeInterpreter.toolCall(fromPayload: event.payload) else {
            respond(id: envelope.id, connection: connection, decision: .ask)
            return
        }

        // Questions are never held: defer so the TUI shows its prompt, and
        // surface an option card that answers by jump + keystroke.
        if let parsed = ClaudeCodeInterpreter.question(fromPayload: event.payload) {
            respond(id: envelope.id, connection: connection, decision: .ask)
            store.addQuestion(QuestionPrompt(
                id: envelope.id,
                sessionID: sessionID,
                question: parsed.question,
                options: parsed.options
            ))
            onNeedsAttention?()
            return
        }

        // Island-side "always allow" rules answer instantly.
        if rules.allows(toolName: call.name, primaryArgument: call.primaryArgument) {
            store.setStatus(sessionID, "✓ Auto-allowed \(call.name): \(call.summary)")
            respond(id: envelope.id, connection: connection, decision: .allow, reason: "aisland always-allow rule")
            return
        }

        let oracle = oracleProvider(event.cwd)
        switch oracle.verdict(toolName: call.name, primaryArgument: call.primaryArgument) {
        case .defer_:
            store.setStatus(sessionID, "\(call.name): \(call.summary)")
            respond(id: envelope.id, connection: connection, decision: .ask)
        case .hold:
            let request = PermissionRequest(
                id: envelope.id,
                sessionID: sessionID,
                toolName: call.name,
                summary: call.summary,
                details: call.details
            )
            gates.register(id: envelope.id, connection: connection)
            store.addRequest(request)
            onNeedsAttention?()
        }
    }

    /// App-layer hook for `islandctl jump` diagnostics: perform a jump for the
    /// given ref and report the outcome string back.
    public var onCtlJump: ((TerminalRef, @escaping @Sendable (String) -> Void) -> Void)?

    private func handleCtl(_ envelope: Envelope<CtlCommand>, connection: SocketConnection) {
        switch envelope.body.command {
        case "jump":
            guard let refJSON = envelope.body.arguments["ref"],
                  let ref = try? WireCodec.decoder.decode(TerminalRef.self, from: Data(refJSON.utf8)),
                  let onCtlJump
            else {
                respond(id: envelope.id, connection: connection, decision: .ask, reason: "jump unavailable")
                return
            }
            let id = envelope.id
            onCtlJump(ref) { [weak self] outcome in
                Task { @MainActor [weak self] in
                    self?.respond(id: id, connection: connection, decision: .ask, reason: outcome)
                }
            }
        default:
            respond(id: envelope.id, connection: connection, decision: .ask, reason: "unknown command")
        }
    }

    private func respond(id: UUID, connection: SocketConnection, decision: GateDecision, reason: String? = nil) {
        let response = GateResponse(decision: decision, reason: reason)
        if let line = try? WireCodec.encodeLine(Envelope(id: id, type: .gateResponse, body: response)) {
            connection.sendLine(line)
        }
        connection.close()
    }

    // MARK: - UI actions

    public func approve(_ request: PermissionRequest) {
        gates.respond(id: request.id, GateResponse(decision: .allow, reason: "Approved from aisland notch"))
        store.removeRequest(id: request.id)
        store.setStatus(request.sessionID, request.isPlanReview ? "✓ Plan approved" : "✓ Approved \(request.toolName)")
    }

    public func deny(_ request: PermissionRequest) {
        gates.respond(id: request.id, GateResponse(decision: .deny, reason: "Denied from aisland notch"))
        store.removeRequest(id: request.id)
        store.setStatus(request.sessionID, request.isPlanReview ? "✕ Plan rejected" : "✕ Denied \(request.toolName)")
    }

    /// Approve + persist an always-allow rule so future matching calls skip the card.
    public func alwaysAllow(_ request: PermissionRequest) {
        let primary: String?
        switch request.details {
        case .bash(let command): primary = command
        case .fileEdit(let path, _, _), .fileWrite(let path, _): primary = path
        default: primary = nil
        }
        rules.addRule(toolName: request.toolName, primaryArgument: primary)
        approve(request)
    }
}
