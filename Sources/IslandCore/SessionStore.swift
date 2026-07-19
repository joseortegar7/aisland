import Foundation
import Observation
import IslandProtocol

public struct SessionID: Hashable, Sendable {
    public let agent: String
    public let raw: String
    public let host: String?

    public init(agent: String, raw: String, host: String? = nil) {
        self.agent = agent
        self.raw = raw
        self.host = host
    }
}

public enum SessionPhase: Sendable, Equatable {
    case working
    case awaitingPermission
    case idle
}

/// A monitored agent session.
public struct SessionState: Identifiable, Sendable {
    public var id: SessionID
    public var cwd: String
    public var terminal: TerminalRef
    /// First user prompt — the card title (like "fix auth bug").
    public var title: String?
    public var statusLine: String?
    public var phase: SessionPhase
    public var todos: [TodoItem]
    public var startedAt: Date
    public var lastActivityAt: Date

    public var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    public var agentDisplayName: String {
        switch id.agent {
        case "claude-code": return "Claude"
        case "codex": return "Codex"
        case "gemini-cli": return "Gemini"
        default: return id.agent.capitalized
        }
    }

    public var terminalDisplayName: String? {
        switch terminal.termProgram {
        case "iTerm.app": return "iTerm"
        case "Apple_Terminal": return "Terminal"
        case "vscode": return "VS Code"
        case "ghostty": return "Ghostty"
        case "WarpTerminal": return "Warp"
        case "WezTerm": return "WezTerm"
        case .some(let other): return other
        case nil: return nil
        }
    }

    public init(
        id: SessionID,
        cwd: String,
        terminal: TerminalRef,
        title: String? = nil,
        statusLine: String? = nil,
        phase: SessionPhase = .working,
        todos: [TodoItem] = [],
        startedAt: Date = Date(),
        lastActivityAt: Date = Date()
    ) {
        self.id = id
        self.cwd = cwd
        self.terminal = terminal
        self.title = title
        self.statusLine = statusLine
        self.phase = phase
        self.todos = todos
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
    }
}

/// Single source of truth for live sessions; all mutation goes through
/// `apply(_:)` and the request/status mutators so state stays headless-testable.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var sessions: [SessionID: SessionState] = [:]
    public private(set) var requests: [PermissionRequest] = []
    public private(set) var questions: [QuestionPrompt] = []

    public var ordered: [SessionState] {
        sessions.values.sorted {
            let leftWaiting = $0.phase == .awaitingPermission
            let rightWaiting = $1.phase == .awaitingPermission
            if leftWaiting != rightWaiting { return leftWaiting }
            return $0.lastActivityAt > $1.lastActivityAt
        }
    }

    public var firstRequest: PermissionRequest? { requests.first }
    public var firstQuestion: QuestionPrompt? { questions.first }
    public var needsAttention: Bool {
        !requests.isEmpty || !questions.isEmpty || sessions.values.contains { $0.phase == .awaitingPermission }
    }

    /// Sound effect hook, wired by the app layer.
    @ObservationIgnored
    public var onSound: ((SoundEvent) -> Void)?

    @ObservationIgnored
    public var onNeedsAttention: (() -> Void)?

    public init() {}

    public func apply(_ event: HookEvent) {
        let id = SessionID(agent: event.agent, raw: event.sessionID, host: event.host)
        switch event.event {
        case "SessionEnd", "sessionEnd":
            sessions[id] = nil
            requests.removeAll { $0.sessionID == id }
            questions.removeAll { $0.sessionID == id }
        default:
            let isNew = sessions[id] == nil
            if isNew { onSound?(.sessionStart) }
            if event.event == "Stop" { onSound?(.done) }
            var session = sessions[id] ?? SessionState(id: id, cwd: event.cwd, terminal: event.terminal)
            session.lastActivityAt = event.timestamp
            session.cwd = event.cwd
            session.terminal = event.terminal
            // Copilot sessions (lifecycle notifications plus permission gates).
            if event.agent == "copilot" {
                let update = CopilotInterpreter.update(event: event.event, payload: event.payload)
                let wasAwaitingPermission = session.phase == .awaitingPermission
                if let status = update.statusLine {
                    session.statusLine = status
                } else if wasAwaitingPermission && update.resolvesAttention {
                    session.statusLine = nil
                }
                if session.title == nil, let title = update.title { session.title = title }
                let remainsAwaitingPermission = update.needsAttention
                    || (wasAwaitingPermission && !update.resolvesAttention)
                session.phase = remainsAwaitingPermission ? .awaitingPermission : (update.idle ? .idle : .working)
                sessions[id] = session
                if update.needsAttention && !wasAwaitingPermission {
                    onSound?(.needsPermission)
                    onNeedsAttention?()
                }
                if update.idle { questions.removeAll { $0.sessionID == id } }
                return
            }
            // Codex notify-only sessions: turn completion is the whole story.
            if event.agent == "codex" {
                if let turn = CodexInterpreter.turnInfo(fromPayload: event.payload) {
                    if session.title == nil { session.title = turn.title }
                    session.statusLine = turn.statusLine
                    session.phase = .idle
                }
                sessions[id] = session
                return
            }
            if let status = ClaudeCodeInterpreter.statusLine(event: event.event, payload: event.payload) {
                session.statusLine = status
            }
            if session.title == nil,
               let prompt = ClaudeCodeInterpreter.promptText(event: event.event, payload: event.payload) {
                session.title = prompt
            }
            if let todos = ClaudeCodeInterpreter.todos(fromPayload: event.payload) {
                session.todos = todos
            }
            if event.event == "Stop" {
                session.phase = .idle
            } else if session.phase != .awaitingPermission {
                session.phase = .working
            }
            sessions[id] = session
            // Fresh activity means any outstanding question card was answered
            // in the terminal — drop stale ones for this session.
            if event.event == "UserPromptSubmit" || event.event == "Stop" {
                questions.removeAll { $0.sessionID == id }
            }
        }
    }

    // MARK: - Permission requests

    public func addRequest(_ request: PermissionRequest) {
        if let key = request.deduplicationKey,
           requests.contains(where: { $0.sessionID == request.sessionID && $0.deduplicationKey == key }) {
            return
        }
        let alreadyAwaiting = sessions[request.sessionID]?.phase == .awaitingPermission
        if !alreadyAwaiting { onSound?(.needsPermission) }
        requests.append(request)
        mutate(request.sessionID) {
            $0.phase = .awaitingPermission
            $0.statusLine = "⚠ \(request.toolName): \(request.summary)"
        }
    }

    public func matchingRequest(sessionID: SessionID, deduplicationKey: String) -> PermissionRequest? {
        requests.first {
            $0.sessionID == sessionID && $0.deduplicationKey == deduplicationKey
        }
    }

    public func removeRequest(id: UUID) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        let request = requests.remove(at: index)
        if !requests.contains(where: { $0.sessionID == request.sessionID }) {
            mutate(request.sessionID) { $0.phase = .working }
        }
    }

    // MARK: - Questions

    public func addQuestion(_ question: QuestionPrompt) {
        onSound?(.question)
        questions.append(question)
        mutate(question.sessionID) {
            $0.statusLine = "❓ \(question.question)"
        }
    }

    public func removeQuestion(id: UUID) {
        questions.removeAll { $0.id == id }
    }

    public func setStatus(_ id: SessionID, _ text: String) {
        mutate(id) { $0.statusLine = text }
    }

    private func mutate(_ id: SessionID, _ change: (inout SessionState) -> Void) {
        guard var session = sessions[id] else { return }
        change(&session)
        session.lastActivityAt = Date()
        sessions[id] = session
    }
}
