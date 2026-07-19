import Foundation
import IslandProtocol

/// Outcome of a jump attempt, from most to least precise.
public enum JumpResult: Sendable, Equatable {
    case exact          // right window, tab, and pane focused
    case windowOnly
    case appOnly
    case failed(String)

    public var succeeded: Bool {
        if case .failed = self { return false }
        return true
    }

    public var label: String {
        switch self {
        case .exact: "exact pane"
        case .windowOnly: "window"
        case .appOnly: "app"
        case .failed(let reason): "failed: \(reason)"
        }
    }
}

/// One terminal's focusing strategy. `score` says how confidently this
/// locator can handle the ref (0 = not mine); highest scorer runs first.
public protocol TerminalLocator: Sendable {
    var id: String { get }
    func score(_ ref: TerminalRef) -> Int
    func focus(_ ref: TerminalRef) async -> JumpResult
}

public final class TerminalJumpResolver: Sendable {
    private let locators: [any TerminalLocator]

    public init(locators: [any TerminalLocator]) {
        self.locators = locators
    }

    public static func standard() -> TerminalJumpResolver {
        TerminalJumpResolver(locators: [
            TmuxLocator(),
            WezTermLocator(),
            KittyLocator(),
            ZellijLocator(),
            ITerm2Locator(),
            AppleTerminalLocator(),
            GhosttyLocator(),
            WarpLocator(),
            VSCodeLocator(),
            AncestorAppLocator(),
        ])
    }

    public func jump(to ref: TerminalRef) async -> JumpResult {
        let ranked = locators
            .map { ($0, $0.score(ref)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        guard !ranked.isEmpty else { return .failed("no locator for \(ref.termProgram ?? "unknown terminal")") }
        var lastFailure = JumpResult.failed("unreachable")
        for (locator, _) in ranked {
            let result = await locator.focus(ref)
            if result.succeeded { return result }
            lastFailure = result
        }
        return lastFailure
    }
}

/// Types option numbers into the frontmost app (the terminal we just jumped
/// to) so AskUserQuestion prompts can be answered from the notch. Requires
/// the Accessibility/Automation grant the app already needs for jumping.
public enum KeystrokeSender {
    /// Press the digit for a 1-based option. Claude Code's question TUI
    /// selects on the digit; no Return needed.
    public static func selectOption(_ index: Int) async -> Bool {
        guard (1...9).contains(index) else { return false }
        let output = await Subprocess.osascript(
            "tell application \"System Events\" to keystroke \"\(index)\""
        )
        return output.status == 0
    }
}

/// Helper for locators shelling out to osascript / CLI tools.
enum Subprocess {
    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let out = Pipe(); let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                    process.waitUntilExit()
                    let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: Output(status: process.terminationStatus, stdout: stdout, stderr: stderr))
                } catch {
                    continuation.resume(returning: Output(status: -1, stdout: "", stderr: "\(error)"))
                }
            }
        }
    }

    static func osascript(_ script: String) async -> Output {
        await run("/usr/bin/osascript", ["-e", script])
    }
}
