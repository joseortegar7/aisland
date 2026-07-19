import Foundation

/// Interprets Codex CLI `notify` payloads. Codex only reports turn
/// completion (no gating — its approvals are TUI-owned), so sessions from
/// Codex are notify-only: they appear, show the last message, and idle.
public enum CodexInterpreter {
    public struct TurnInfo: Sendable {
        public let title: String?
        public let statusLine: String
    }

    public static func turnInfo(fromPayload payload: Data) -> TurnInfo? {
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              (object["type"] as? String)?.contains("turn-complete") == true
        else { return nil }
        let firstInput = (object["input-messages"] as? [String])?.first
            ?? (object["input_messages"] as? [String])?.first
        let lastMessage = (object["last-assistant-message"] as? String)
            ?? (object["last_assistant_message"] as? String)
        let status = lastMessage.map { text in
            let flattened = text.replacingOccurrences(of: "\n", with: " ")
            return flattened.count <= 100 ? flattened : String(flattened.prefix(99)) + "…"
        }
        return TurnInfo(
            title: firstInput.map { $0.count <= 60 ? $0 : String($0.prefix(59)) + "…" },
            statusLine: status ?? "Turn complete — click to jump"
        )
    }
}

/// Sets the `notify` program in ~/.codex/config.toml. Line-based TOML edit:
/// backup-first, idempotent (marker = "island-shim"), preserves everything
/// else byte-for-byte.
public struct CodexNotifyInstaller: Sendable {
    public let configPath: String
    public let shimPath: String

    public init(
        configPath: String = NSHomeDirectory() + "/.codex/config.toml",
        shimPath: String
    ) {
        self.configPath = configPath
        self.shimPath = shimPath
    }

    public enum Health: Equatable, Sendable {
        case installed, missing
        case conflicting(String)   // notify set to someone else's program
    }

    public func health() -> Health {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return .missing }
        guard let line = notifyLine(in: text) else { return .missing }
        return line.contains("island-shim") ? .installed : .conflicting(line)
    }

    public func install() throws {
        var text = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        if let existing = notifyLine(in: text), existing.contains("island-shim") { return }

        // Backup once.
        let backupPath = configPath + ".aisland.bak"
        if FileManager.default.fileExists(atPath: configPath),
           !FileManager.default.fileExists(atPath: backupPath) {
            try FileManager.default.copyItem(atPath: configPath, toPath: backupPath)
        }

        let notifyLineText = "notify = [\"\(shimPath)\", \"codex\", \"Notify\", \"--json-arg\"]"
        if notifyLine(in: text) != nil {
            // Replace the existing top-level notify line, preserving the rest.
            text = text
                .components(separatedBy: "\n")
                .map { isTopLevelNotify($0) ? notifyLineText : $0 }
                .joined(separator: "\n")
        } else {
            // Top-level keys must precede any [section] table. Insert before
            // the first section header, or append if there is none.
            var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
            if let sectionIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) {
                lines.insert(notifyLineText, at: sectionIndex)
            } else {
                lines.append(notifyLineText)
            }
            text = lines.joined(separator: "\n")
        }
        if !text.hasSuffix("\n") { text += "\n" }
        try FileManager.default.createDirectory(
            atPath: (configPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }

    public func uninstall() throws {
        guard var text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        guard let line = notifyLine(in: text), line.contains("island-shim") else { return }
        text = text
            .components(separatedBy: "\n")
            .filter { !(isTopLevelNotify($0) && $0.contains("island-shim")) }
            .joined(separator: "\n")
        try Data(text.utf8).write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }

    private func notifyLine(in text: String) -> String? {
        // Only top-level `notify =` lines count; `[section]` keys don't.
        var inSection = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { inSection = true; continue }
            if !inSection && isTopLevelNotify(line) { return line }
        }
        return nil
    }

    private func isTopLevelNotify(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("notify") &&
            trimmed.dropFirst("notify".count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
    }
}

/// Which agent CLIs exist on this machine, and whether our integration for
/// them is live. Drives the "Agent Status" menu.
public struct AgentDetector: Sendable {
    public struct Detection: Sendable {
        public let id: String
        public let displayName: String
        public let installed: Bool
        public let integration: String   // "hooks", "notify", "none yet"
    }

    public init() {}

    public func scan(home: String = NSHomeDirectory(), shimPath: String) -> [Detection] {
        let claudeHealth = ClaudeHookInstaller(shimPath: shimPath).health()
        let codexHealth = CodexNotifyInstaller(shimPath: shimPath).health()
        return [
            Detection(
                id: "claude-code", displayName: "Claude Code",
                installed: exists("\(home)/.claude") || binaryExists("claude"),
                integration: claudeHealth == .installed ? "hooks ✓" : "hooks not installed"
            ),
            Detection(
                id: "codex", displayName: "Codex CLI",
                installed: exists("\(home)/.codex") || binaryExists("codex"),
                integration: codexHealth == .installed ? "notify ✓" : "notify not installed"
            ),
            Detection(
                id: "copilot", displayName: "GitHub Copilot (CLI + VS Code)",
                installed: exists("\(home)/.copilot") || binaryExists("copilot"),
                integration: CopilotHookInstaller(shimPath: shimPath).health() == .installed
                    ? "hooks ✓" : "hooks not installed"
            ),
            Detection(
                id: "gemini-cli", displayName: "Gemini CLI",
                installed: exists("\(home)/.gemini") || binaryExists("gemini"),
                integration: "none yet"
            ),
            Detection(
                id: "opencode", displayName: "OpenCode",
                installed: exists("\(home)/.opencode") || binaryExists("opencode"),
                integration: "none yet"
            ),
            Detection(
                id: "cursor-agent", displayName: "Cursor Agent",
                installed: binaryExists("cursor-agent"),
                integration: "none yet"
            ),
        ]
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private func binaryExists(_ name: String) -> Bool {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        return paths.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
    }
}
