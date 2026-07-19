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
        // Surface 1: our own hook file for the VS Code agent.
        try FileManager.default.createDirectory(atPath: hooksDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: legacyHookFilePath)
        let hookEntries = Self.pascalEvents.reduce(into: [String: Any]()) { result, event in
            result[event] = [["type": "command", "command": command(event: event)]]
        }
        let hookFile: [String: Any] = ["hooks": hookEntries]
        let hookData = try JSONSerialization.data(withJSONObject: hookFile, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try hookData.write(to: URL(fileURLWithPath: hookFilePath), options: .atomic)

        // Surface 2: merge into settings.json for the CLI.
        var settings: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: settingsPath),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            settings = existing
            let backupPath = settingsPath + ".aisland.bak"
            if !FileManager.default.fileExists(atPath: backupPath) {
                try? data.write(to: URL(fileURLWithPath: backupPath))
            }
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in Self.camelEvents {
            var entries = (hooks[event] as? [[String: Any]] ?? []).filter { entry in
                !entryIsOurs(entry)
            }
            entries.append([
                "type": "command",
                "bash": "\(shimPath) copilot \(event)",
                "powershell": "\(shimPath) copilot \(event)",
                "timeoutSec": 10,
            ])
            hooks[event] = entries
        }
        settings["hooks"] = hooks
        let settingsData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try settingsData.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
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
    }

    public static func update(event: String, payload: Data) -> Update {
        let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        let input = object?["input"] as? [String: Any]
        let value: (String) -> String? = { key in
            (object?[key] as? String) ?? (input?[key] as? String)
        }
        switch event {
        case "Stop", "agentStop":
            return Update(statusLine: "Done — click to jump", title: nil, idle: true)
        case "UserPromptSubmit", "userPromptSubmit", "userPromptSubmitted":
            let prompt = value("prompt") ?? value("message") ?? value("userPrompt")
            let flattened = prompt?.replacingOccurrences(of: "\n", with: " ")
            return Update(
                statusLine: flattened.map { "You: " + String($0.prefix(100)) },
                title: flattened.map { String($0.prefix(60)) },
                idle: false
            )
        case "permissionRequest":
            return Update(statusLine: "⚠ Needs approval in terminal", title: nil, idle: false)
        case "notification", "errorOccurred":
            let message = value("message") ?? value("text")
            return Update(statusLine: message.map { String($0.prefix(120)) }, title: nil, idle: false)
        case "SessionStart", "sessionStart":
            return Update(statusLine: "Session started", title: nil, idle: false)
        case "PreToolUse", "preToolUse":
            let tool = value("tool_name") ?? value("toolName")
            return Update(statusLine: tool.map { "Running \($0)" }, title: nil, idle: false)
        case "PostToolUse", "postToolUse":
            let tool = value("tool_name") ?? value("toolName")
            return Update(statusLine: tool.map { "Finished \($0)" }, title: nil, idle: false)
        case "PostToolUseFailure", "postToolUseFailure":
            let tool = value("tool_name") ?? value("toolName")
            return Update(statusLine: "Failed \(tool ?? "tool")", title: nil, idle: false)
        case "SubagentStart", "subagentStart":
            return Update(statusLine: "Subagent started", title: nil, idle: false)
        case "SubagentStop", "subagentStop":
            return Update(statusLine: "Subagent finished", title: nil, idle: false)
        case "preCompact":
            return Update(statusLine: "Compacting context", title: nil, idle: false)
        default:
            return Update(statusLine: nil, title: nil, idle: false)
        }
    }
}
