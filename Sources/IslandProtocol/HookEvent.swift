import Foundation

/// Identity of the terminal pane a hook fired from, captured by the shim at
/// invocation time. Locators use whichever fields their terminal exposes.
public struct TerminalRef: Codable, Sendable, Equatable {
    public var tty: String?
    public var pid: Int32
    public var ancestorPIDs: [Int32]
    public var termProgram: String?
    public var termSessionID: String?
    public var itermSessionID: String?
    public var tmuxSocket: String?
    public var tmuxPane: String?
    public var weztermPane: String?
    public var kittyWindowID: String?
    public var zellijSession: String?

    public init(
        tty: String? = nil,
        pid: Int32 = 0,
        ancestorPIDs: [Int32] = [],
        termProgram: String? = nil,
        termSessionID: String? = nil,
        itermSessionID: String? = nil,
        tmuxSocket: String? = nil,
        tmuxPane: String? = nil,
        weztermPane: String? = nil,
        kittyWindowID: String? = nil,
        zellijSession: String? = nil
    ) {
        self.tty = tty
        self.pid = pid
        self.ancestorPIDs = ancestorPIDs
        self.termProgram = termProgram
        self.termSessionID = termSessionID
        self.itermSessionID = itermSessionID
        self.tmuxSocket = tmuxSocket
        self.tmuxPane = tmuxPane
        self.weztermPane = weztermPane
        self.kittyWindowID = kittyWindowID
        self.zellijSession = zellijSession
    }

    /// Capture from the current process environment (the shim runs inside the
    /// terminal pane the agent runs in, so its own environment is the pane's).
    public static func captureCurrent(environment: [String: String] = ProcessInfo.processInfo.environment) -> TerminalRef {
        var ref = TerminalRef()
        ref.pid = ProcessInfo.processInfo.processIdentifier
        ref.tty = currentTTYName()
        ref.ancestorPIDs = ancestorChain(of: ref.pid)
        ref.termProgram = environment["TERM_PROGRAM"]
        ref.termSessionID = environment["TERM_SESSION_ID"]
        ref.itermSessionID = environment["ITERM_SESSION_ID"]
        if let tmux = environment["TMUX"] {
            ref.tmuxSocket = tmux.split(separator: ",").first.map(String.init)
        }
        ref.tmuxPane = environment["TMUX_PANE"]
        ref.weztermPane = environment["WEZTERM_PANE"]
        ref.kittyWindowID = environment["KITTY_WINDOW_ID"]
        ref.zellijSession = environment["ZELLIJ_SESSION_NAME"]
        return ref
    }

    private static func currentTTYName() -> String? {
        for fd: Int32 in [0, 1, 2] {
            if let name = ttyname(fd) {
                return String(cString: name).replacingOccurrences(of: "/dev/", with: "")
            }
        }
        return nil
    }

    /// Walk the parent-PID chain so locators can find the owning terminal app.
    private static func ancestorChain(of pid: Int32, maxDepth: Int = 12) -> [Int32] {
        var chain: [Int32] = []
        var current = pid
        for _ in 0..<maxDepth {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
            let ppid = info.kp_eproc.e_ppid
            guard ppid > 1 else { break }
            chain.append(ppid)
            current = ppid
        }
        return chain
    }
}

/// A lifecycle or gating event forwarded from an agent hook.
public struct HookEvent: Codable, Sendable {
    /// Agent identifier, e.g. "claude-code".
    public var agent: String
    /// Agent-native event name, e.g. "PreToolUse", "SessionStart".
    public var event: String
    public var sessionID: String
    public var cwd: String
    public var transcriptPath: String?
    public var terminal: TerminalRef
    /// Raw hook stdin JSON; interpreted by the agent's adapter in the app.
    public var payload: Data
    /// nil = local machine; hostname for SSH-forwarded sessions.
    public var host: String?
    public var timestamp: Date

    public init(
        agent: String,
        event: String,
        sessionID: String,
        cwd: String,
        transcriptPath: String? = nil,
        terminal: TerminalRef,
        payload: Data,
        host: String? = nil,
        timestamp: Date = Date()
    ) {
        self.agent = agent
        self.event = event
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.terminal = terminal
        self.payload = payload
        self.host = host
        self.timestamp = timestamp
    }
}
