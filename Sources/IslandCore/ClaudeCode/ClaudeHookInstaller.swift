import Foundation

/// Installs/removes aisland's hook entries in Claude Code's settings.
/// Backup-first, idempotent (marker = command containing "island-shim"),
/// atomic writes, and every touched file recorded in a manifest so uninstall
/// can restore byte-identical state.
public struct ClaudeHookInstaller: Sendable {
    public let settingsPath: String
    public let shimPath: String
    public let manifestPath: String

    /// Events forwarded fire-and-forget. PreToolUse is the only gate.
    static let lifecycleEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "Notification"]

    public init(
        settingsPath: String = NSHomeDirectory() + "/.claude/settings.json",
        shimPath: String,
        manifestPath: String = SocketServer.supportDirectory.appendingPathComponent("installed.json").path
    ) {
        self.settingsPath = settingsPath
        self.shimPath = shimPath
        self.manifestPath = manifestPath
    }

    public enum Health: Equatable, Sendable {
        case installed
        case missing
        /// Installed but pointing at a shim that no longer exists.
        case stale(String)
    }

    public func health() -> Health {
        guard let settings = readSettings() else { return .missing }
        let commands = allHookCommands(in: settings)
        let ours = commands.filter { $0.contains("island-shim") }
        guard !ours.isEmpty else { return .missing }
        for command in ours {
            let binary = command.split(separator: " ").first.map(String.init) ?? ""
            if !FileManager.default.fileExists(atPath: binary) { return .stale(binary) }
        }
        return .installed
    }

    public func install() throws {
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsPath) {
            guard let existing = readSettings() else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSFilePathErrorKey: settingsPath,
                    NSLocalizedDescriptionKey: "Existing Claude settings are not valid JSON.",
                ])
            }
            settings = existing
        }
        try backupOnce()

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        hooks = removingOurEntries(from: hooks)

        // PreToolUse gate: blocks until the app answers (or defers instantly).
        hooks["PreToolUse"] = (hooks["PreToolUse"] as? [[String: Any]] ?? []) + [entry(
            command: "\(shimPath) claude-code PreToolUse --gate",
            timeout: 3600
        )]
        for event in Self.lifecycleEvents {
            hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + [entry(
                command: "\(shimPath) claude-code \(event)",
                timeout: 10
            )]
        }
        settings["hooks"] = hooks
        try writeSettings(settings)
        try recordInManifest()
    }

    public func uninstall() throws {
        guard var settings = readSettings() else { return }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        hooks = removingOurEntries(from: hooks)
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        try writeSettings(settings)
    }

    // MARK: - Internals

    private func entry(command: String, timeout: Int) -> [String: Any] {
        [
            "matcher": "",
            "hooks": [["type": "command", "command": command, "timeout": timeout]],
        ]
    }

    func removingOurEntries(from hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let matchers = value as? [[String: Any]] else {
                result[event] = value
                continue
            }
            let kept = matchers.compactMap { matcher -> [String: Any]? in
                guard let entries = matcher["hooks"] as? [[String: Any]] else {
                    return matcher
                }
                let foreignEntries = entries.filter {
                    ($0["command"] as? String)?.contains("island-shim") != true
                }
                guard !foreignEntries.isEmpty else { return nil }
                var updated = matcher
                updated["hooks"] = foreignEntries
                return updated
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    private func allHookCommands(in settings: [String: Any]) -> [String] {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return hooks.values.flatMap { value -> [String] in
            (value as? [[String: Any]] ?? []).flatMap { matcher in
                (matcher["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
            }
        }
    }

    private func readSettings() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: settingsPath) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        let directory = (settingsPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
    }

    private func backupOnce() throws {
        let backupPath = settingsPath + ".aisland.bak"
        guard FileManager.default.fileExists(atPath: settingsPath),
              !FileManager.default.fileExists(atPath: backupPath)
        else { return }
        try FileManager.default.copyItem(atPath: settingsPath, toPath: backupPath)
    }

    private func recordInManifest() throws {
        var manifest: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: manifestPath),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            manifest = existing
        }
        var files = Set(manifest["files"] as? [String] ?? [])
        files.insert(settingsPath)
        manifest["files"] = files.sorted()
        manifest["installedAt"] = ISO8601DateFormatter().string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            atPath: (manifestPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try data.write(to: URL(fileURLWithPath: manifestPath), options: .atomic)
    }
}
