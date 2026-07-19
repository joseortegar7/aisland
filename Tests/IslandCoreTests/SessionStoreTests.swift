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
}
