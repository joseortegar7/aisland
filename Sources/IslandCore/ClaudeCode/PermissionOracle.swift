import Foundation

/// Predicts whether Claude Code would prompt for a given tool call, by
/// mirroring its permission config. If Claude would auto-allow, we answer the
/// gate with "ask" immediately (defer to Claude, zero friction). Only calls
/// Claude would prompt for become notch approval cards.
///
/// This is a best-effort mirror of the rule syntax: exact tool names,
/// `Tool(prefix:*)` prefix rules, and `Tool(literal)` exact rules. Unknown
/// syntax errs on the side of showing a card (never silently allows).
public struct PermissionOracle: Sendable {
    public enum PermissionMode: String, Sendable, Equatable {
        case `default`
        case acceptEdits
        case plan
        case bypassPermissions
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
    }

    private let allowRules: [Rule]
    private let defaultMode: PermissionMode?

    struct Rule: Sendable {
        let tool: String
        /// nil = bare tool rule ("Bash") allowing every input.
        let spec: Spec?

        enum Spec: Sendable {
            case prefix(String)   // "git status:*" → prefix "git status"
            case exact(String)
        }
    }

    public init(allowPatterns: [String], defaultMode: PermissionMode? = nil) {
        allowRules = allowPatterns.compactMap(Self.parse(pattern:))
        self.defaultMode = defaultMode
    }

    /// Load allow rules the way Claude Code layers them: user settings, user
    /// local, project, project local.
    public static func loadForProject(cwd: String, home: String = NSHomeDirectory()) -> PermissionOracle {
        let candidates = [
            "\(home)/.claude/settings.json",
            "\(home)/.claude/settings.local.json",
            "\(cwd)/.claude/settings.json",
            "\(cwd)/.claude/settings.local.json",
        ]
        var patterns: [String] = []
        var defaultMode: PermissionMode?
        for path in candidates {
            guard let data = FileManager.default.contents(atPath: path),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let permissions = object["permissions"] as? [String: Any]
            else { continue }
            patterns.append(contentsOf: permissions["allow"] as? [String] ?? [])
            if let rawMode = permissions["defaultMode"] as? String,
               let mode = PermissionMode(rawValue: rawMode) {
                defaultMode = mode
            }
        }
        return PermissionOracle(allowPatterns: patterns, defaultMode: defaultMode)
    }

    public func verdict(
        toolName: String,
        primaryArgument: String?,
        permissionMode: PermissionMode? = nil
    ) -> Verdict {
        switch permissionMode ?? defaultMode ?? .default {
        case .bypassPermissions, .plan:
            return .defer_
        case .acceptEdits where Self.editTools.contains(toolName):
            return .defer_
        case .default, .acceptEdits:
            break
        }
        if Self.alwaysSafeTools.contains(toolName) { return .defer_ }
        return matches(toolName: toolName, primaryArgument: primaryArgument) ? .defer_ : .hold
    }

    private static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    /// Pure pattern matching, without the safe-tool shortcut. Also used by
    /// ApprovalRulesStore for island-side "always allow" rules.
    public func matches(toolName: String, primaryArgument: String?) -> Bool {
        for rule in allowRules where rule.tool == toolName {
            switch rule.spec {
            case nil:
                return true
            case .prefix(let prefix):
                if let argument = primaryArgument, argument.hasPrefix(prefix) { return true }
            case .exact(let literal):
                if primaryArgument == literal { return true }
            }
        }
        return false
    }

    static func parse(pattern: String) -> Rule? {
        guard let open = pattern.firstIndex(of: "(") else {
            let tool = pattern.trimmingCharacters(in: .whitespaces)
            return tool.isEmpty ? nil : Rule(tool: tool, spec: nil)
        }
        guard pattern.hasSuffix(")") else { return nil }
        let tool = String(pattern[..<open])
        var body = String(pattern[pattern.index(after: open)..<pattern.index(before: pattern.endIndex)])
        if body.hasSuffix(":*") {
            body.removeLast(2)
            return Rule(tool: tool, spec: .prefix(body))
        }
        if body == "*" || body.isEmpty {
            return Rule(tool: tool, spec: nil)
        }
        return Rule(tool: tool, spec: .exact(body))
    }
}
