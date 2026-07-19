import XCTest
@testable import IslandProtocol

final class WireCodecTests: XCTestCase {
    func testEnvelopeRoundTrip() throws {
        let event = HookEvent(
            agent: "claude-code",
            event: "PreToolUse",
            sessionID: "abc-123",
            cwd: "/tmp/project",
            transcriptPath: "/tmp/transcript.jsonl",
            terminal: TerminalRef(tty: "ttys003", pid: 42, termProgram: "iTerm.app"),
            payload: Data(#"{"tool_name":"Bash"}"#.utf8)
        )
        let envelope = Envelope(type: .gateRequest, body: event)
        let line = try WireCodec.encodeLine(envelope)

        XCTAssertEqual(line.last, 0x0A)

        let header = try WireCodec.decodeHeader(line)
        XCTAssertEqual(header.v, wireProtocolVersion)
        XCTAssertEqual(header.type, .gateRequest)
        XCTAssertEqual(header.id, envelope.id)

        let decoded = try WireCodec.decode(HookEvent.self, from: line)
        XCTAssertEqual(decoded.body.agent, "claude-code")
        XCTAssertEqual(decoded.body.sessionID, "abc-123")
        XCTAssertEqual(decoded.body.terminal.tty, "ttys003")
        XCTAssertEqual(decoded.body.payload, event.payload)
    }

    func testGateResponseRoundTrip() throws {
        let response = GateResponse(decision: .deny, reason: "user denied from notch")
        let line = try WireCodec.encodeLine(Envelope(type: .gateResponse, body: response))
        let decoded = try WireCodec.decode(GateResponse.self, from: line)
        XCTAssertEqual(decoded.body.decision, .deny)
        XCTAssertEqual(decoded.body.reason, "user denied from notch")
    }

    func testTerminalRefCaptureFromEnvironment() {
        let env = [
            "TERM_PROGRAM": "iTerm.app",
            "ITERM_SESSION_ID": "w0t0p0:UUID",
            "TMUX": "/private/tmp/tmux-501/default,1234,0",
            "TMUX_PANE": "%3",
        ]
        let ref = TerminalRef.captureCurrent(environment: env)
        XCTAssertEqual(ref.termProgram, "iTerm.app")
        XCTAssertEqual(ref.itermSessionID, "w0t0p0:UUID")
        XCTAssertEqual(ref.tmuxSocket, "/private/tmp/tmux-501/default")
        XCTAssertEqual(ref.tmuxPane, "%3")
        XCTAssertEqual(ref.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertFalse(ref.ancestorPIDs.isEmpty)
    }
}
