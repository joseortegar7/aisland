import AppKit
import Foundation
import IslandProtocol

/// Shared helpers for app-level activation.
enum AppActivation {
    /// Walk the shim's ancestor PIDs and activate the first real GUI app —
    /// this is the terminal (or editor) hosting the agent's pane.
    @discardableResult
    static func activateAncestorApp(_ ref: TerminalRef) -> Bool {
        for pid in ref.ancestorPIDs {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular
            else { continue }
            return app.activate(options: [.activateIgnoringOtherApps])
        }
        return false
    }

    @discardableResult
    static func activateBundle(_ bundleID: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return false
        }
        return app.activate(options: [.activateIgnoringOtherApps])
    }

    static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.fileExists(atPath: $0) }
    }
}

/// WezTerm: exact pane focus via its CLI, then raise the app.
public struct WezTermLocator: TerminalLocator {
    public let id = "wezterm"

    public init() {}

    public func score(_ ref: TerminalRef) -> Int {
        if ref.weztermPane != nil { return 110 }
        if ref.termProgram == "WezTerm" { return 90 }
        return 0
    }

    public func focus(_ ref: TerminalRef) async -> JumpResult {
        let raised = await MainActor.run {
            AppActivation.activateBundle("com.github.wez.wezterm") || AppActivation.activateAncestorApp(ref)
        }
        guard let pane = ref.weztermPane,
              let binary = AppActivation.firstExisting([
                  "/opt/homebrew/bin/wezterm",
                  "/usr/local/bin/wezterm",
                  "/Applications/WezTerm.app/Contents/MacOS/wezterm",
              ])
        else { return raised ? .appOnly : .failed("wezterm not found") }
        let output = await Subprocess.run(binary, ["cli", "activate-pane", "--pane-id", pane])
        return output.status == 0 ? .exact : (raised ? .appOnly : .failed("wezterm cli: \(output.stderr)"))
    }
}

/// Kitty: exact window focus via remote control (needs `allow_remote_control`
/// in kitty.conf); degrades to app activation.
public struct KittyLocator: TerminalLocator {
    public let id = "kitty"

    public init() {}

    public func score(_ ref: TerminalRef) -> Int {
        ref.kittyWindowID != nil ? 110 : 0
    }

    public func focus(_ ref: TerminalRef) async -> JumpResult {
        let raised = await MainActor.run {
            AppActivation.activateBundle("net.kovidgoyal.kitty") || AppActivation.activateAncestorApp(ref)
        }
        guard let windowID = ref.kittyWindowID,
              let binary = AppActivation.firstExisting([
                  "/opt/homebrew/bin/kitty",
                  "/usr/local/bin/kitty",
                  "/Applications/kitty.app/Contents/MacOS/kitty",
              ])
        else { return raised ? .appOnly : .failed("kitty not found") }
        let output = await Subprocess.run(binary, ["@", "focus-window", "--match", "id:\(windowID)"])
        return output.status == 0 ? .exact : (raised ? .appOnly : .failed("kitty remote control disabled?"))
    }
}

/// Zellij runs inside another terminal; select its pane, then let the
/// ancestor walk raise whatever hosts the zellij client.
public struct ZellijLocator: TerminalLocator {
    public let id = "zellij"

    public init() {}

    public func score(_ ref: TerminalRef) -> Int {
        ref.zellijSession != nil ? 105 : 0
    }

    public func focus(_ ref: TerminalRef) async -> JumpResult {
        let raised = await MainActor.run { AppActivation.activateAncestorApp(ref) }
        return raised ? .windowOnly : .failed("no GUI ancestor for zellij session")
    }
}

/// Ghostty: app-level activation (AX-based pane matching is a later phase).
public struct GhosttyLocator: TerminalLocator {
    public let id = "ghostty"

    public init() {}

    public func score(_ ref: TerminalRef) -> Int {
        ref.termProgram?.lowercased() == "ghostty" ? 95 : 0
    }

    public func focus(_ ref: TerminalRef) async -> JumpResult {
        let raised = await MainActor.run {
            AppActivation.activateBundle("com.mitchellh.ghostty") || AppActivation.activateAncestorApp(ref)
        }
        return raised ? .appOnly : .failed("Ghostty not running")
    }
}

/// Warp: app-level activation.
public struct WarpLocator: TerminalLocator {
    public let id = "warp"

    public init() {}

    public func score(_ ref: TerminalRef) -> Int {
        ref.termProgram == "WarpTerminal" ? 95 : 0
    }

    public func focus(_ ref: TerminalRef) async -> JumpResult {
        let raised = await MainActor.run {
            AppActivation.activateBundle("dev.warp.Warp-Stable") || AppActivation.activateAncestorApp(ref)
        }
        return raised ? .appOnly : .failed("Warp not running")
    }
}

/// VS Code / Cursor integrated terminals: the ancestor walk resolves to the
/// right editor app (Code vs Cursor) automatically.
public struct VSCodeLocator: TerminalLocator {
    public let id = "vscode"

    public init() {}

    public func score(_ ref: TerminalRef) -> Int {
        ref.termProgram == "vscode" ? 95 : 0
    }

    public func focus(_ ref: TerminalRef) async -> JumpResult {
        let raised = await MainActor.run { AppActivation.activateAncestorApp(ref) }
        return raised ? .appOnly : .failed("editor not running")
    }
}

/// Last resort for any terminal we don't know: raise the GUI app that
/// ultimately owns the agent's process.
public struct AncestorAppLocator: TerminalLocator {
    public let id = "ancestor"

    public init() {}

    public func score(_ ref: TerminalRef) -> Int {
        ref.ancestorPIDs.isEmpty ? 0 : 10
    }

    public func focus(_ ref: TerminalRef) async -> JumpResult {
        let raised = await MainActor.run { AppActivation.activateAncestorApp(ref) }
        return raised ? .appOnly : .failed("no GUI ancestor found")
    }
}
