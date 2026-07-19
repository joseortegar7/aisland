import Foundation
import IslandProtocol

/// iTerm2: match the session by tty (or ITERM_SESSION_ID) via AppleScript.
public struct ITerm2Locator: TerminalLocator {
    public let id = "iterm2"

    public init() {}

    public func score(_ ref: TerminalRef) -> Int {
        if ref.itermSessionID != nil { return 100 }
        if ref.termProgram == "iTerm.app" { return 90 }
        return 0
    }

    public func focus(_ ref: TerminalRef) async -> JumpResult {
        guard let tty = ref.tty else { return .failed("no tty captured") }
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "/dev/\(tty)" then
                            select w
                            tell w to select t
                            tell t to select s
                            activate
                            return "exact"
                        end if
                    end repeat
                end repeat
            end repeat
            return "notfound"
        end tell
        """
        let output = await Subprocess.osascript(script)
        guard output.status == 0 else { return .failed("osascript: \(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        if output.stdout.contains("exact") { return .exact }
        // Session gone or tty mismatch: at least raise the app.
        let raised = await Subprocess.osascript(#"tell application "iTerm2" to activate"#)
        return raised.status == 0 ? .appOnly : .failed("session not found")
    }
}

/// Terminal.app: tabs expose their tty directly.
public struct AppleTerminalLocator: TerminalLocator {
    public let id = "terminal"

    public init() {}

    public func score(_ ref: TerminalRef) -> Int {
        ref.termProgram == "Apple_Terminal" ? 90 : 0
    }

    public func focus(_ ref: TerminalRef) async -> JumpResult {
        guard let tty = ref.tty else { return .failed("no tty captured") }
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/\(tty)" then
                        set selected of t to true
                        set frontmost of w to true
                        activate
                        return "exact"
                    end if
                end repeat
            end repeat
            return "notfound"
        end tell
        """
        let output = await Subprocess.osascript(script)
        guard output.status == 0 else { return .failed("osascript: \(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        if output.stdout.contains("exact") { return .exact }
        let raised = await Subprocess.osascript(#"tell application "Terminal" to activate"#)
        return raised.status == 0 ? .appOnly : .failed("tab not found")
    }
}

/// tmux: select the right pane, then focus the terminal hosting an attached
/// client (recursing into the iTerm2/Terminal locators via a synthetic ref).
public struct TmuxLocator: TerminalLocator {
    public let id = "tmux"

    static let tmuxCandidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]

    public init() {}

    public func score(_ ref: TerminalRef) -> Int {
        ref.tmuxPane != nil ? 120 : 0
    }

    public func focus(_ ref: TerminalRef) async -> JumpResult {
        guard let pane = ref.tmuxPane,
              let tmux = Self.tmuxCandidates.first(where: { FileManager.default.fileExists(atPath: $0) })
        else { return .failed("tmux not found") }

        var socketArguments: [String] = []
        if let socket = ref.tmuxSocket { socketArguments = ["-S", socket] }

        // Find the session/window owning the pane, then select it.
        let list = await Subprocess.run(tmux, socketArguments + [
            "list-panes", "-a", "-F", "#{pane_id} #{session_name} #{window_index}",
        ])
        guard list.status == 0 else { return .failed("tmux list-panes: \(list.stderr)") }
        guard let line = list.stdout.split(separator: "\n").first(where: { $0.hasPrefix(pane + " ") }) else {
            return .failed("pane \(pane) not found")
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return .failed("unexpected tmux output") }
        let session = String(parts[1]); let window = String(parts[2])

        _ = await Subprocess.run(tmux, socketArguments + ["select-window", "-t", "\(session):\(window)"])
        _ = await Subprocess.run(tmux, socketArguments + ["select-pane", "-t", pane])
        _ = await Subprocess.run(tmux, socketArguments + ["switch-client", "-t", session])

        // Focus the terminal window hosting an attached client for this session.
        let clients = await Subprocess.run(tmux, socketArguments + [
            "list-clients", "-F", "#{client_tty} #{client_session}",
        ])
        if let clientLine = clients.stdout.split(separator: "\n").first(where: { $0.hasSuffix(" " + session) }) {
            let clientTTY = String(clientLine.split(separator: " ")[0]).replacingOccurrences(of: "/dev/", with: "")
            var outer = TerminalRef()
            outer.tty = clientTTY
            outer.termProgram = ref.termProgram
            outer.itermSessionID = ref.itermSessionID
            for locator: any TerminalLocator in [ITerm2Locator(), AppleTerminalLocator()] where locator.score(outer) > 0 {
                let result = await locator.focus(outer)
                if result.succeeded { return .exact }
            }
        }
        return .windowOnly
    }
}
