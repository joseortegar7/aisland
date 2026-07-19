import Foundation

/// GitHub Copilot integration. `~/.copilot/hooks/aisland.json` is the canonical
/// registration. Lifecycle hooks are notify-only; permissionRequest blocks on
/// the shim until the user chooses Allow or Deny.
public struct CopilotHookInstaller: Sendable {
    public let hooksDirectory: String
    public let settingsPath: String
    public let shimPath: String

    static let events = [
        "sessionStart", "sessionEnd", "userPromptSubmitted",
        "preToolUse", "postToolUse", "postToolUseFailure", "preCompact",
        "subagentStart", "subagentStop", "agentStop", "notification",
        "permissionRequest", "errorOccurred",
    ]

    public init(
        copilotDirectory: String = NSHomeDirectory() + "/.copilot",
        shimPath: String
    ) {
        self.hooksDirectory = copilotDirectory + "/hooks"
        self.settingsPath = copilotDirectory + "/settings.json"
        self.shimPath = shimPath
    }

    var hookFilePath: String { hooksDirectory + "/aisland.json" }
    private var legacyHookFilePath: String { hooksDirectory + "/copyisland.json" }

    /// Guarded and fail-open: a missing app/shim leaves Copilot's native prompt.
    private func command(event: String, gate: Bool = false) -> String {
        let gateArgument = gate ? " --gate" : ""
        return "/bin/sh -c '[ -x \"\(shimPath)\" ] && \"\(shimPath)\" copilot \(event)\(gateArgument); exit 0'"
    }

    public enum Health: Equatable, Sendable {
        case installed, missing, partial
    }

    public func health() -> Health {
        let fileInstalled = hookFileIsCanonical()
        let legacySettingsInstalled = settingsHasOurEntries()
        if fileInstalled && !legacySettingsInstalled { return .installed }
        if FileManager.default.fileExists(atPath: hookFilePath) || legacySettingsInstalled { return .partial }
        return .missing
    }

    public func install() throws {
        let hookEntries = Self.events.reduce(into: [String: Any]()) { result, event in
            result[event] = [[
                "type": "command",
                "command": command(event: event, gate: event == "permissionRequest"),
                "timeoutSec": event == "permissionRequest" ? 3600 : 10,
            ]]
        }
        let hookFile: [String: Any] = ["version": 1, "hooks": hookEntries]
        let hookData = try JSONSerialization.data(withJSONObject: hookFile, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

        var updatedSettingsData: Data?
        var existingSettingsData: Data?
        if let data = FileManager.default.contents(atPath: settingsPath) {
            guard let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSFilePathErrorKey: settingsPath,
                    NSLocalizedDescriptionKey: "Existing Copilot settings are not valid JSON.",
                ])
            }
            existingSettingsData = data
            let cleaned = removingOurEntries(from: existing)
            updatedSettingsData = try JSONSerialization.data(
                withJSONObject: cleaned,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        }

        try FileManager.default.createDirectory(atPath: hooksDirectory, withIntermediateDirectories: true)
        if let existingSettingsData {
            let backupPath = settingsPath + ".aisland.bak"
            if !FileManager.default.fileExists(atPath: backupPath) {
                try existingSettingsData.write(to: URL(fileURLWithPath: backupPath), options: .atomic)
            }
        }
        try hookData.write(to: URL(fileURLWithPath: hookFilePath), options: .atomic)
        if let updatedSettingsData, updatedSettingsData != existingSettingsData {
            try updatedSettingsData.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        }
        try? FileManager.default.removeItem(atPath: legacyHookFilePath)
    }

    public func uninstall() throws {
        try? FileManager.default.removeItem(atPath: hookFilePath)
        try? FileManager.default.removeItem(atPath: legacyHookFilePath)
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        let cleaned = removingOurEntries(from: settings)
        let settingsData = try JSONSerialization.data(withJSONObject: cleaned, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try settingsData.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
    }

    private func removingOurEntries(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !entryIsOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    private func entryIsOurs(_ entry: [String: Any]) -> Bool {
        for key in ["bash", "powershell", "command"] {
            if (entry[key] as? String)?.contains("island-shim") == true { return true }
        }
        return false
    }

    private func settingsHasOurEntries() -> Bool {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any]
        else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { entryIsOurs($0) }
        }
    }

    private func hookFileIsCanonical() -> Bool {
        guard let data = FileManager.default.contents(atPath: hookFilePath),
              let file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              file["version"] as? Int == 1,
              let hooks = file["hooks"] as? [String: Any],
              Set(hooks.keys) == Set(Self.events)
        else { return false }
        return Self.events.allSatisfy { event in
            guard let entries = hooks[event] as? [[String: Any]], entries.count == 1,
                  let entry = entries.first,
                  let command = entry["command"] as? String,
                  command.contains("island-shim"),
                  entry["timeoutSec"] as? Int == (event == "permissionRequest" ? 3600 : 10)
            else { return false }
            return event == "permissionRequest"
                ? command.contains("permissionRequest --gate")
                : !command.contains("--gate")
        }
    }
}

/// Status interpretation for Copilot hook events (both surfaces' spellings).
public enum CopilotInterpreter {
    public struct Update: Sendable {
        public let statusLine: String?
        public let title: String?
        public let idle: Bool
        public let needsAttention: Bool
        public let resolvesAttention: Bool
    }

    public static func update(event: String, payload: Data) -> Update {
        let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        let value: ([String]) -> String? = { keys in
            firstString(for: keys, in: object)
        }

        switch event {
        case "Stop", "agentStop":
            return Update(statusLine: "Done — click to jump", title: nil, idle: true, needsAttention: false, resolvesAttention: true)
        case "UserPromptSubmit", "userPromptSubmit", "userPromptSubmitted":
            let prompt = value(["prompt", "message", "userPrompt"])
            let flattened = prompt?.replacingOccurrences(of: "\n", with: " ")
            return Update(
                statusLine: flattened.map { "You: " + String($0.prefix(100)) },
                title: flattened.map { String($0.prefix(60)) },
                idle: false,
                needsAttention: false,
                resolvesAttention: false
            )
        case "PermissionRequest", "permissionRequest":
            let tool = value(["tool_name", "toolName", "name"])
            let status = tool.map { "⚠ Needs approval for \($0)" } ?? "⚠ Needs approval in terminal"
            return Update(statusLine: status, title: nil, idle: false, needsAttention: true, resolvesAttention: false)
        case "notification":
            let message = value(["message", "text"])
            let notificationType = value(["notification_type", "notificationType"])
            return Update(
                statusLine: message.map { String($0.prefix(120)) },
                title: nil,
                idle: false,
                needsAttention: notificationType == "permission_prompt",
                resolvesAttention: false
            )
        case "errorOccurred":
            let message = value(["message", "text"])
            return Update(statusLine: message.map { String($0.prefix(120)) }, title: nil, idle: false, needsAttention: false, resolvesAttention: true)
        case "SessionStart", "sessionStart":
            return Update(statusLine: "Session started", title: nil, idle: false, needsAttention: false, resolvesAttention: false)
        case "PreToolUse", "preToolUse":
            let tool = value(["tool_name", "toolName", "name"])
            return Update(statusLine: tool.map { "Running \($0)" }, title: nil, idle: false, needsAttention: false, resolvesAttention: false)
        case "PostToolUse", "postToolUse":
            let tool = value(["tool_name", "toolName", "name"])
            return Update(statusLine: tool.map { "Finished \($0)" }, title: nil, idle: false, needsAttention: false, resolvesAttention: true)
        case "PostToolUseFailure", "postToolUseFailure":
            let tool = value(["tool_name", "toolName", "name"])
            return Update(statusLine: "Failed \(tool ?? "tool")", title: nil, idle: false, needsAttention: false, resolvesAttention: true)
        case "SubagentStart", "subagentStart":
            return Update(statusLine: "Subagent started", title: nil, idle: false, needsAttention: false, resolvesAttention: false)
        case "SubagentStop", "subagentStop":
            return Update(statusLine: "Subagent finished", title: nil, idle: false, needsAttention: false, resolvesAttention: false)
        case "preCompact":
            return Update(statusLine: "Compacting context", title: nil, idle: false, needsAttention: false, resolvesAttention: false)
        default:
            return Update(statusLine: nil, title: nil, idle: false, needsAttention: false, resolvesAttention: false)
        }
    }

    public static func permissionRequest(
        id: UUID,
        sessionID: SessionID,
        payload: Data
    ) -> PermissionRequest? {
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let toolName = firstString(for: ["toolName", "tool_name"], in: object)
        else { return nil }
        let inputValue = firstValue(for: ["toolInput", "tool_input", "toolArgs", "tool_args"], in: object)
        let input = normalizedObject(inputValue)
        let primaryArgument = primaryArgument(toolName: toolName, input: input)
        let nativeID = firstString(
            for: ["toolCallId", "tool_call_id", "requestId", "request_id", "permissionRequestId"],
            in: object
        )
        let canonicalInput = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? String(describing: inputValue)
        return PermissionRequest(
            id: id,
            sessionID: sessionID,
            toolName: toolName,
            summary: summary(toolName: toolName, primaryArgument: primaryArgument, input: input),
            details: details(toolName: toolName, input: input),
            primaryArgument: primaryArgument,
            canPersistApproval: false,
            deduplicationKey: nativeID ?? "\(sessionID.raw)|\(toolName)|\(canonicalInput)"
        )
    }

    public static func resolvesAllPermissionGates(event: String) -> Bool {
        switch event {
        case "SessionEnd", "sessionEnd", "Stop", "agentStop", "errorOccurred",
             "cancelled", "canceled":
            return true
        default:
            return false
        }
    }

    public static func completedToolCallID(event: String, payload: Data) -> String? {
        guard ["PostToolUse", "postToolUse", "PostToolUseFailure", "postToolUseFailure"].contains(event),
              let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        else { return nil }
        return firstString(
            for: ["toolCallId", "tool_call_id", "requestId", "request_id", "permissionRequestId"],
            in: object
        )
    }

    private static func details(toolName: String, input: [String: Any]) -> RequestDetails {
        switch toolName.lowercased() {
        case "bash", "powershell", "shell", "terminal":
            return .bash(command: string(["command", "script", "input"], in: input) ?? "")
        case "edit", "apply_patch", "str_replace_editor":
            return .fileEdit(
                path: string(["filePath", "file_path", "path"], in: input) ?? "?",
                old: string(["oldString", "old_string", "oldText", "old_text"], in: input) ?? "",
                new: string(["newString", "new_string", "newText", "new_text", "patch"], in: input) ?? ""
            )
        case "create", "write":
            return .fileWrite(
                path: string(["filePath", "file_path", "path"], in: input) ?? "?",
                content: string(["content", "text"], in: input) ?? ""
            )
        default:
            let data = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return .generic(json: String(data: data.prefix(2_000), encoding: .utf8) ?? "")
        }
    }

    private static func primaryArgument(toolName: String, input: [String: Any]) -> String? {
        switch toolName.lowercased() {
        case "bash", "powershell", "shell", "terminal":
            return string(["command", "script", "input"], in: input)
        case "edit", "apply_patch", "str_replace_editor", "create", "write", "view":
            return string(["filePath", "file_path", "path"], in: input)
        case "web_fetch":
            return string(["url"], in: input)
        case "web_search":
            return string(["query", "url"], in: input)
        default:
            return string(["url", "path", "command", "query"], in: input)
        }
    }

    private static func summary(toolName: String, primaryArgument: String?, input: [String: Any]) -> String {
        if let primaryArgument, !primaryArgument.isEmpty {
            return primaryArgument.count <= 120 ? primaryArgument : String(primaryArgument.prefix(119)) + "…"
        }
        let keys = input.keys.sorted().prefix(3).joined(separator: ", ")
        return keys.isEmpty ? toolName : "\(toolName)(\(keys))"
    }

    private static func normalizedObject(_ value: Any?) -> [String: Any] {
        if let object = value as? [String: Any] { return object }
        if let string = value as? String,
           let data = string.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return object
        }
        if let string = value as? String { return ["value": string] }
        return [:]
    }

    private static func string(_ keys: [String], in object: [String: Any]) -> String? {
        firstString(for: keys, in: object)
    }

    private static func firstValue(for keys: [String], in value: Any?, depth: Int = 0) -> Any? {
        guard depth <= 4 else { return nil }
        if let object = value as? [String: Any] {
            for key in keys {
                if let value = object[key] { return value }
            }
            for nested in object.values {
                if let value = firstValue(for: keys, in: nested, depth: depth + 1) { return value }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let value = firstValue(for: keys, in: nested, depth: depth + 1) { return value }
            }
        }
        return nil
    }

    private static func firstString(for keys: [String], in value: Any?, depth: Int = 0) -> String? {
        guard depth <= 3 else { return nil }
        if let object = value as? [String: Any] {
            for key in keys {
                if let string = object[key] as? String, !string.isEmpty { return string }
            }
            for nested in object.values {
                if let string = firstString(for: keys, in: nested, depth: depth + 1) { return string }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let string = firstString(for: keys, in: nested, depth: depth + 1) { return string }
            }
        }
        return nil
    }
}
