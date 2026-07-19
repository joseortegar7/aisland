import Foundation
import Observation

/// Island-side "always allow" rules, persisted across launches. These are OUR
/// rules (answered with an immediate `allow` at the gate), independent of
/// Claude's own allowlist — same pattern syntax, evaluated via PermissionOracle.
@MainActor
@Observable
public final class ApprovalRulesStore {
    public private(set) var patterns: [String] = []

    @ObservationIgnored
    private let path: String

    public init(path: String = SocketServer.supportDirectory.appendingPathComponent("approval-rules.json").path) {
        self.path = path
        load()
    }

    public func allows(toolName: String, primaryArgument: String?) -> Bool {
        PermissionOracle(allowPatterns: patterns)
            .matches(toolName: toolName, primaryArgument: primaryArgument)
    }

    /// Derive and persist a rule from an approved request.
    /// Bash → prefix rule on the first token ("git push …" → `Bash(git:*)`);
    /// everything else → bare tool rule.
    public func addRule(toolName: String, primaryArgument: String?) {
        let pattern: String
        if toolName == "Bash", let first = primaryArgument?.split(separator: " ").first {
            pattern = "\(toolName)(\(first):*)"
        } else {
            pattern = toolName
        }
        guard !patterns.contains(pattern) else { return }
        patterns.append(pattern)
        save()
    }

    public func removeAll() {
        patterns = []
        save()
    }

    private func load() {
        guard let data = FileManager.default.contents(atPath: path),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stored = object["patterns"] as? [String]
        else { return }
        patterns = stored
    }

    private func save() {
        let object: [String: Any] = ["patterns": patterns]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
