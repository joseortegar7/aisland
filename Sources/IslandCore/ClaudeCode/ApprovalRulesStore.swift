import Foundation
import Observation

/// Island-side "always allow" rules, persisted across launches. These are OUR
/// rules (answered with an immediate `allow` at the gate), independent of
/// Claude's own allowlist — same pattern syntax, evaluated via PermissionOracle.
@MainActor
@Observable
public final class ApprovalRulesStore {
    private struct ExactRule: Codable, Equatable {
        let toolName: String
        let primaryArgument: String
    }

    private struct StoredRules: Codable {
        let version: Int
        let rules: [ExactRule]
    }

    private static let formatVersion = 3

    public private(set) var patterns: [String] = []

    @ObservationIgnored
    private let path: String
    @ObservationIgnored
    private var exactRules: [ExactRule] = []

    public init(path: String = SocketServer.supportDirectory.appendingPathComponent("approval-rules.json").path) {
        self.path = path
        load()
    }

    public func allows(toolName: String, primaryArgument: String?) -> Bool {
        guard let primaryArgument else { return false }
        return exactRules.contains {
            $0.toolName == toolName && $0.primaryArgument == primaryArgument
        }
    }

    /// Persist an exact argument rule. Broad prefix and bare-tool rules can
    /// silently authorize materially different operations.
    public func addRule(toolName: String, primaryArgument: String) throws {
        let rule = ExactRule(toolName: toolName, primaryArgument: primaryArgument)
        guard !exactRules.contains(rule) else { return }
        let updatedRules = exactRules + [rule]
        try save(updatedRules)
        exactRules = updatedRules
        refreshPatterns()
    }

    public func removeAll() throws {
        try save([])
        exactRules = []
        refreshPatterns()
    }

    private func load() {
        guard let data = FileManager.default.contents(atPath: path),
              let stored = try? JSONDecoder().decode(StoredRules.self, from: data),
              stored.version == Self.formatVersion
        else { return }
        exactRules = stored.rules
        refreshPatterns()
    }

    private func save(_ rules: [ExactRule]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(StoredRules(version: Self.formatVersion, rules: rules))
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func refreshPatterns() {
        patterns = exactRules.map { "\($0.toolName)(\($0.primaryArgument))" }
    }
}
