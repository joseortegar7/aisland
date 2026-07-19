import Foundation
import IslandProtocol

/// Structured detail of what a gated tool call wants to do, for rich cards.
public enum RequestDetails: Sendable, Equatable {
    case bash(command: String)
    case fileEdit(path: String, old: String, new: String)
    case fileWrite(path: String, content: String)
    case plan(markdown: String)
    case generic(json: String)
}

/// A gate awaiting user decision, rendered as an approval card.
public struct PermissionRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let sessionID: SessionID
    public let toolName: String
    /// Human summary of the tool input: the command, the file path, the URL…
    public let summary: String
    public let details: RequestDetails
    public let receivedAt: Date

    public var isPlanReview: Bool {
        if case .plan = details { return true }
        return false
    }

    public init(id: UUID, sessionID: SessionID, toolName: String, summary: String, details: RequestDetails, receivedAt: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.toolName = toolName
        self.summary = summary
        self.details = details
        self.receivedAt = receivedAt
    }
}

/// An AskUserQuestion prompt surfaced as an option card. Answering happens by
/// jumping to the terminal and typing the option number (the TUI owns the
/// actual prompt; we never hold the gate for questions).
public struct QuestionPrompt: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let sessionID: SessionID
    public let question: String
    public let options: [String]
    public let receivedAt: Date

    public init(id: UUID, sessionID: SessionID, question: String, options: [String], receivedAt: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.question = question
        self.options = options
        self.receivedAt = receivedAt
    }
}

public struct TodoItem: Sendable, Equatable {
    public enum Status: String, Sendable { case pending, inProgress = "in_progress", completed }
    public let content: String
    public let status: Status

    public init(content: String, status: Status) {
        self.content = content
        self.status = status
    }
}

/// Interprets Claude Code hook payloads. Tolerant by design: unknown shapes
/// degrade to generic status text, never failures.
public enum ClaudeCodeInterpreter {
    public struct ToolCall: Sendable {
        public let name: String
        public let summary: String
        public let details: RequestDetails
        public let permissionMode: PermissionOracle.PermissionMode?
        /// The primary string argument permission rules match against
        /// (Bash command, file path, URL).
        public let primaryArgument: String?
    }

    public static func toolCall(fromPayload payload: Data) -> ToolCall? {
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let name = object["tool_name"] as? String
        else { return nil }
        let input = object["tool_input"] as? [String: Any] ?? [:]
        let primary = primaryArgument(toolName: name, input: input)
        return ToolCall(
            name: name,
            summary: summary(toolName: name, primary: primary, input: input),
            details: details(toolName: name, input: input),
            permissionMode: (object["permission_mode"] as? String).flatMap(PermissionOracle.PermissionMode.init(rawValue:)),
            primaryArgument: primary
        )
    }

    static func details(toolName: String, input: [String: Any]) -> RequestDetails {
        switch toolName {
        case "Bash":
            return .bash(command: input["command"] as? String ?? "")
        case "Edit":
            return .fileEdit(
                path: input["file_path"] as? String ?? "?",
                old: input["old_string"] as? String ?? "",
                new: input["new_string"] as? String ?? ""
            )
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            let first = edits.first ?? [:]
            return .fileEdit(
                path: (input["file_path"] as? String ?? "?") + (edits.count > 1 ? "  (+\(edits.count - 1) more edits)" : ""),
                old: first["old_string"] as? String ?? "",
                new: first["new_string"] as? String ?? ""
            )
        case "Write":
            return .fileWrite(
                path: input["file_path"] as? String ?? "?",
                content: input["content"] as? String ?? ""
            )
        case "ExitPlanMode":
            return .plan(markdown: input["plan"] as? String ?? "(empty plan)")
        default:
            let data = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return .generic(json: String(data: data.prefix(2000), encoding: .utf8) ?? "")
        }
    }

    /// AskUserQuestion tool → option card (first question; TUI handles the rest).
    public static func question(fromPayload payload: Data) -> (question: String, options: [String])? {
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              object["tool_name"] as? String == "AskUserQuestion",
              let input = object["tool_input"] as? [String: Any],
              let questions = input["questions"] as? [[String: Any]],
              let first = questions.first,
              let text = first["question"] as? String
        else { return nil }
        let options = (first["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        return (text, options)
    }

    /// TodoWrite tool → checklist for the session card.
    public static func todos(fromPayload payload: Data) -> [TodoItem]? {
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              object["tool_name"] as? String == "TodoWrite",
              let input = object["tool_input"] as? [String: Any],
              let raw = input["todos"] as? [[String: Any]]
        else { return nil }
        return raw.compactMap { item in
            guard let content = item["content"] as? String else { return nil }
            let status = TodoItem.Status(rawValue: item["status"] as? String ?? "pending") ?? .pending
            return TodoItem(content: content, status: status)
        }
    }

    static func primaryArgument(toolName: String, input: [String: Any]) -> String? {
        switch toolName {
        case "Bash": return input["command"] as? String
        case "Edit", "Write", "MultiEdit", "Read", "NotebookEdit":
            return input["file_path"] as? String
        case "WebFetch", "WebSearch": return (input["url"] as? String) ?? (input["query"] as? String)
        case "Task": return input["description"] as? String
        case "Glob", "Grep": return input["pattern"] as? String
        default: return nil
        }
    }

    static func summary(toolName: String, primary: String?, input: [String: Any]) -> String {
        if let primary, !primary.isEmpty {
            return truncate(primary, to: 120)
        }
        if input.isEmpty { return toolName }
        let keys = input.keys.sorted().prefix(3).joined(separator: ", ")
        return "\(toolName)(\(keys))"
    }

    /// Status line for fire-and-forget lifecycle events; nil = leave unchanged.
    public static func statusLine(event: String, payload: Data) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        switch event {
        case "UserPromptSubmit":
            guard let prompt = object?["prompt"] as? String, !prompt.isEmpty else { return nil }
            return "You: " + truncate(prompt.replacingOccurrences(of: "\n", with: " "), to: 100)
        case "Stop":
            return "Done — click to jump"
        case "Notification":
            guard let message = object?["message"] as? String else { return nil }
            return truncate(message, to: 120)
        case "SessionStart":
            return "Session started"
        default:
            return nil
        }
    }

    /// The user's prompt text, used as the session card title.
    public static func promptText(event: String, payload: Data) -> String? {
        guard event == "UserPromptSubmit",
              let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let prompt = object["prompt"] as? String, !prompt.isEmpty
        else { return nil }
        return truncate(prompt.replacingOccurrences(of: "\n", with: " "), to: 60)
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}
