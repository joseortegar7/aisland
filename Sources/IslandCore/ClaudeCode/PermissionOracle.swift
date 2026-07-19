import Foundation

/// Predicts whether Claude Code would prompt for a given tool call, by
/// mirroring its permission config. If Claude would auto-allow, we answer the
/// gate with "ask" immediately (defer to Claude, zero friction). Only calls
/// Claude would prompt for become notch approval cards.
///
/// This is a best-effort mirror of Claude's permission precedence and wildcard
/// syntax. Unknown syntax errs on the side of showing a card.
public struct PermissionOracle: Sendable {
    public enum PermissionMode: String, Sendable, Equatable {
        case `default`
        case acceptEdits
        case plan
        case auto
        case dontAsk
        case bypassPermissions

        static func parse(_ value: String) -> PermissionMode? {
            value == "manual" ? .default : PermissionMode(rawValue: value)
        }
    }

    /// Tools Claude Code never prompts for.
    public static let alwaysSafeTools: Set<String> = [
        "Read", "Glob", "Grep", "LS", "NotebookRead", "TodoRead", "TodoWrite",
        "Task", "BashOutput", "TaskList", "TaskGet",
    ]

    public enum Verdict: Sendable, Equatable {
        /// Claude would not prompt — defer (answer "ask" with no card).
        case defer_
        /// Claude would prompt — hold the gate and show a card.
        case hold
        /// An explicit ask rule requires a fresh decision; stored aisland rules
        /// must not satisfy it automatically.
        case holdWithoutStoredApproval
    }

    private let allowRules: [Rule]
    private let denyRules: [Rule]
    private let askRules: [Rule]
    private let defaultMode: PermissionMode?

    struct Rule: Sendable {
        let tool: String
        /// nil = bare tool rule ("Bash") allowing every input.
        let spec: String?
    }

    public init(
        allowPatterns: [String],
        denyPatterns: [String] = [],
        askPatterns: [String] = [],
        defaultMode: PermissionMode? = nil
    ) {
        allowRules = allowPatterns.compactMap(Self.parse(pattern:))
        denyRules = denyPatterns.compactMap(Self.parse(pattern:))
        askRules = askPatterns.compactMap(Self.parse(pattern:))
        self.defaultMode = defaultMode
    }

    /// Load permission rules the way Claude Code layers them: user settings,
    /// project settings, legacy local settings, then managed policy.
    public static func loadForProject(cwd: String, home: String = NSHomeDirectory()) -> PermissionOracle {
        var candidates = [
            "\(home)/.claude/settings.json",
            "\(home)/.claude/settings.local.json",
        ]
        let projectRoot = projectRoot(for: cwd)
        candidates += [
            "\(projectRoot)/.claude/settings.json",
            "\(projectRoot)/.claude/settings.local.json",
        ]
        if projectRoot != URL(fileURLWithPath: cwd).standardizedFileURL.path {
            // Claude still reads legacy settings left in the starting directory.
            candidates += [
                "\(cwd)/.claude/settings.json",
                "\(cwd)/.claude/settings.local.json",
            ]
        }
        candidates += managedSettingsPaths()

        var allowPatterns: [String] = []
        var denyPatterns: [String] = []
        var askPatterns: [String] = []
        var defaultMode: PermissionMode?
        var seenPaths: Set<String> = []
        for path in candidates where seenPaths.insert(path).inserted {
            guard let data = FileManager.default.contents(atPath: path),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let permissions = object["permissions"] as? [String: Any]
            else { continue }
            allowPatterns.append(contentsOf: permissions["allow"] as? [String] ?? [])
            denyPatterns.append(contentsOf: permissions["deny"] as? [String] ?? [])
            askPatterns.append(contentsOf: permissions["ask"] as? [String] ?? [])
            if let rawMode = permissions["defaultMode"] as? String,
               let mode = PermissionMode.parse(rawMode) {
                defaultMode = mode
            }
        }
        return PermissionOracle(
            allowPatterns: allowPatterns,
            denyPatterns: denyPatterns,
            askPatterns: askPatterns,
            defaultMode: defaultMode
        )
    }

    public func verdict(
        toolName: String,
        primaryArgument: String?,
        permissionMode: PermissionMode? = nil
    ) -> Verdict {
        // Claude evaluates deny, ask, then allow. Never let an aisland rule
        // bypass a deny or satisfy a newly-added explicit ask rule.
        if matches(denyRules, toolName: toolName, primaryArgument: primaryArgument) {
            return .defer_
        }
        if matches(askRules, toolName: toolName, primaryArgument: primaryArgument) {
            return .holdWithoutStoredApproval
        }
        if matches(allowRules, toolName: toolName, primaryArgument: primaryArgument) {
            return .defer_
        }

        switch permissionMode ?? defaultMode ?? .default {
        case .bypassPermissions, .plan, .auto, .dontAsk:
            return .defer_
        case .acceptEdits where Self.editTools.contains(toolName):
            return .defer_
        case .default, .acceptEdits:
            break
        }
        if Self.alwaysSafeTools.contains(toolName) { return .defer_ }
        return .hold
    }

    private static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    /// Pure pattern matching, without the safe-tool shortcut. Also used by
    /// ApprovalRulesStore for island-side "always allow" rules.
    public func matches(toolName: String, primaryArgument: String?) -> Bool {
        matches(allowRules, toolName: toolName, primaryArgument: primaryArgument)
    }

    private func matches(_ rules: [Rule], toolName: String, primaryArgument: String?) -> Bool {
        for rule in rules where rule.tool == toolName {
            guard let spec = rule.spec else { return true }
            guard let primaryArgument else { continue }
            if Self.glob(spec, matches: primaryArgument) { return true }
        }
        return false
    }

    static func parse(pattern: String) -> Rule? {
        guard let open = pattern.firstIndex(of: "(") else {
            let tool = pattern.trimmingCharacters(in: .whitespaces)
            return tool.isEmpty ? nil : Rule(tool: tool, spec: nil)
        }
        guard pattern.hasSuffix(")") else { return nil }
        let tool = pattern[..<open].trimmingCharacters(in: .whitespaces)
        guard !tool.isEmpty else { return nil }
        var body = String(pattern[pattern.index(after: open)..<pattern.index(before: pattern.endIndex)])
        if body.hasSuffix(":*") {
            body.removeLast(2)
            body += "*"
        }
        if body == "*" || body.isEmpty {
            return Rule(tool: tool, spec: nil)
        }
        return Rule(tool: tool, spec: body)
    }

    private static func glob(_ pattern: String, matches value: String) -> Bool {
        let expression = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        return value.range(of: "^\(expression)$", options: .regularExpression) != nil
    }

    private static func projectRoot(for cwd: String) -> String {
        var directory = URL(fileURLWithPath: cwd).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            directory.deleteLastPathComponent()
        }
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return directory.path
            }
            directory.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: cwd).standardizedFileURL.path
    }

    private static func managedSettingsPaths() -> [String] {
        let directory = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode")
        var paths = [directory.appendingPathComponent("managed-settings.json").path]
        let dropIns = directory.appendingPathComponent("managed-settings.d")
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: dropIns,
            includingPropertiesForKeys: nil
        ) {
            paths += entries
                .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { $0.path }
        }
        return paths
    }
}
