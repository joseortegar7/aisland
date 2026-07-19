import Foundation

/// The user's (or a rule's) verdict on a blocking gate request.
public enum GateDecision: String, Codable, Sendable {
    case allow
    case deny
    /// Defer to the agent's own prompt (same as the shim's fail-open path).
    case ask
}

/// app → shim answer to a `gateRequest`.
public struct GateResponse: Codable, Sendable {
    public var decision: GateDecision
    public var reason: String?
    /// Optional selected option index for multi-question prompts.
    public var optionIndex: Int?
    /// Optional free-text feedback (plan review).
    public var feedback: String?

    public init(decision: GateDecision, reason: String? = nil, optionIndex: Int? = nil, feedback: String? = nil) {
        self.decision = decision
        self.reason = reason
        self.optionIndex = optionIndex
        self.feedback = feedback
    }
}

public enum NativeGateOutput {
    public static func encode(agent: String, event: String, response: GateResponse) throws -> Data? {
        guard response.decision == .allow || response.decision == .deny else { return nil }
        let output: [String: Any]
        switch agent {
        case "claude-code":
            output = [
                "hookSpecificOutput": [
                    "hookEventName": event,
                    "permissionDecision": response.decision.rawValue,
                    "permissionDecisionReason": response.reason ?? "Decided from aisland notch",
                ],
            ]
        case "copilot":
            if response.decision == .allow {
                output = ["behavior": "allow"]
            } else {
                output = [
                    "behavior": "deny",
                    "message": response.reason ?? "Denied from aisland notch",
                ]
            }
        default:
            return nil
        }
        return try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    }
}

/// islandctl → app commands for development and testing.
public struct CtlCommand: Codable, Sendable {
    public var command: String
    public var arguments: [String: String]

    public init(command: String, arguments: [String: String] = [:]) {
        self.command = command
        self.arguments = arguments
    }
}

/// Sent by an SSH-forwarded shim before its first event.
public struct RemoteHello: Codable, Sendable {
    public var host: String

    public init(host: String) {
        self.host = host
    }
}
