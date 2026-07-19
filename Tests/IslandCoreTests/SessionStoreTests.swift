import XCTest
import IslandProtocol
@testable import IslandCore

final class SessionStoreTests: XCTestCase {
    @MainActor
    func testSessionLifecycle() {
        let store = SessionStore()

        let start = HookEvent(
            agent: "claude-code",
            event: "SessionStart",
            sessionID: "s1",
            cwd: "/tmp/project",
            terminal: TerminalRef(tty: "ttys001", pid: 1),
            payload: Data()
        )
        store.apply(start)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.ordered.first?.cwd, "/tmp/project")

        let end = HookEvent(
            agent: "claude-code",
            event: "SessionEnd",
            sessionID: "s1",
            cwd: "/tmp/project",
            terminal: TerminalRef(tty: "ttys001", pid: 1),
            payload: Data()
        )
        store.apply(end)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    @MainActor
    func testSessionsFromDifferentAgentsDoNotCollide() {
        let store = SessionStore()
        for agent in ["claude-code", "codex"] {
            let event = HookEvent(
                agent: agent,
                event: "SessionStart",
                sessionID: "same-raw-id",
                cwd: "/tmp",
                terminal: TerminalRef(),
                payload: Data()
            )
            store.apply(event)
        }
        XCTAssertEqual(store.sessions.count, 2)
    }

    @MainActor
    func testCopilotCamelCaseSessionEndRemovesSession() {
        let store = SessionStore()
        let start = HookEvent(
            agent: "copilot",
            event: "sessionStart",
            sessionID: "vscode-session",
            cwd: "/tmp/project",
            terminal: TerminalRef(termProgram: "vscode"),
            payload: Data()
        )
        store.apply(start)
        XCTAssertEqual(store.sessions.count, 1)

        let end = HookEvent(
            agent: "copilot",
            event: "sessionEnd",
            sessionID: "vscode-session",
            cwd: "/tmp/project",
            terminal: TerminalRef(termProgram: "vscode"),
            payload: Data()
        )
        store.apply(end)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    @MainActor
    func testCopilotPermissionRequestsAttentionAndClearsOnActivity() {
        let store = SessionStore()
        var sounds: [SoundEvent] = []
        var attentionCount = 0
        store.onSound = { sounds.append($0) }
        store.onNeedsAttention = { attentionCount += 1 }
        let terminal = TerminalRef(termProgram: "vscode")

        store.apply(HookEvent(
            agent: "copilot", event: "permissionRequest", sessionID: "waiting",
            cwd: "/tmp/waiting", terminal: terminal,
            payload: Data(#"{"arguments":{"toolName":"terminal"}}"#.utf8)
        ))
        store.apply(HookEvent(
            agent: "copilot", event: "sessionStart", sessionID: "other",
            cwd: "/tmp/other", terminal: terminal, payload: Data()
        ))

        let waitingID = SessionID(agent: "copilot", raw: "waiting")
        XCTAssertEqual(store.sessions[waitingID]?.phase, .awaitingPermission)
        XCTAssertEqual(store.ordered.first?.id, waitingID)
        XCTAssertTrue(store.needsAttention)
        XCTAssertEqual(sounds.filter { $0 == .needsPermission }.count, 1)
        XCTAssertEqual(attentionCount, 1)

        store.apply(HookEvent(
            agent: "copilot", event: "PostToolUse", sessionID: "waiting",
            cwd: "/tmp/waiting", terminal: terminal,
            payload: Data(#"{"tool_input":{"toolName":"terminal"}}"#.utf8)
        ))
        XCTAssertEqual(store.sessions[waitingID]?.phase, .working)
        XCTAssertEqual(store.sessions[waitingID]?.statusLine, "Finished terminal")
        XCTAssertFalse(store.needsAttention)
    }
}
