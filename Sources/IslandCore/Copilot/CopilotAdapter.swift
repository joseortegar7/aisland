import Foundation

/// GitHub Copilot integration. Two surfaces share ~/.copilot:
///  • `~/.copilot/hooks/<name>.json` — PascalCase events, consumed by the
///    VS Code Copilot agent. We own our whole file, so install/uninstall is
///    just create/delete — other tools' hook files are never touched.
///  • `~/.copilot/settings.json` `hooks` — camelCase events, consumed by the
///    Copilot CLI. We merge our entries into the arrays (marker: island-shim).
/// Copilot hooks are notify-only for us: no gating, always `exit 0`.
public struct CopilotHookInstaller: Sendable {
    public let hooksDirectory: String
    public let settingsPath: String
    public let shimPath: String

    static let pascalEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
        "PostToolUse", "PostToolUseFailure", "Stop", "SubagentStart", "SubagentStop",
        "PermissionRequest",
    ]
    static let camelEvents = [
        "sessionStart", "sessionEnd", "userPromptSubmit", "userPromptSubmitted",
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

    /// Guarded, fail-open command: only runs if the shim exists, always exits 0.
    private func command(event: String) -> String {
        "/bin/sh -c '[ -x \"\(shimPath)\" ] && \"\(shimPath)\" copilot \(event); exit 0'"
    }

    public enum Health: Equatable, Sendable {
        case installed, missing, partial
    }

    public func health() -> Health {
        let fileInstalled = FileManager.default.fileExists(atPath: hookFilePath)
        let settingsInstalled = settingsHasOurEntries()
        if fileInstalled && settingsInstalled { return .installed }
        if fileInstalled || settingsInstalled { return .partial }
        return .missing
    }

    public func install() throws {
        let hookEntries = Self.pascalEvents.reduce(into: [String: Any]()) { result, event in
            result[event] = [["type": "command", "command": command(event: event)]]
        }
        let hookFile: [String: Any] = ["version": 1, "hooks": hookEntries]
        let hookData = try JSONSerialization.data(withJSONObject: hookFile, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

        var settings: [String: Any] = [:]
        var existingSettingsData: Data?
        if let data = FileManager.default.contents(atPath: settingsPath) {
            guard let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSFilePathErrorKey: settingsPath,
                    NSLocalizedDescriptionKey: "Existing Copilot settings are not valid JSON.",
                ])
            }
            settings = existing
            existingSettingsData = data
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in Self.camelEvents {
            var entries = (hooks[event] as? [[String: Any]] ?? []).filter { entry in
                !entryIsOurs(entry)
            }
            entries.append([
                "type": "command",
                "bash": command(event: event),
                "powershell": command(event: event),
                "timeoutSec": 10,
            ])
            hooks[event] = entries
        }
        settings["hooks"] = hooks
        let settingsData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

        try FileManager.default.createDirectory(atPath: hooksDirectory, withIntermediateDirectories: true)
        if let existingSettingsData {
            let backupPath = settingsPath + ".aisland.bak"
            if !FileManager.default.fileExists(atPath: backupPath) {
                try existingSettingsData.write(to: URL(fileURLWithPath: backupPath), options: .atomic)
            }
        }
        try settingsData.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        try hookData.write(to: URL(fileURLWithPath: hookFilePath), options: .atomic)
        try? FileManager.default.removeItem(atPath: legacyHookFilePath)
    }

    public func uninstall() throws {
        try? FileManager.default.removeItem(atPath: hookFilePath)
        try? FileManager.default.removeItem(atPath: legacyHookFilePath)
        guard let data = FileManager.default.contents(atPath: settingsPath),
              var settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any]
        else { return }
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !entryIsOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        let settingsData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try settingsData.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
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
