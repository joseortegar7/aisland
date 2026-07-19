import AppKit
import IslandCore
import NotchUI
import TerminalJump

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NotchActions {
    private var controllers: [NotchController] = []

    private let store = SessionStore()
    private let gates = GateCenter()
    private var router: IslandRouter!
    private let server = SocketServer()
    private let resolver = TerminalJumpResolver.standard()
    private let usage = UsageTracker()
    private let sounds = SoundEngine()

    /// Stable path the installed hook config points at; survives app moves.
    static let shimSymlinkPath = NSHomeDirectory() + "/.aisland/bin/island-shim"
    static let legacyShimSymlinkPath = NSHomeDirectory() + "/.copyisland/bin/island-shim"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            try ensureShimSymlink()
            try repairLegacyShimSymlink()
            try repairInstalledCopilotHooks()
        } catch {
            NSLog("aisland: integration repair failed: \(error)")
        }

        router = IslandRouter(store: store, gates: gates)
        router.onNeedsAttention = { [weak self] in
            self?.controllers.first?.setExpanded(true)
        }
        router.onError = { [weak self] message in
            self?.notifyUser("aisland error", message)
        }
        store.onNeedsAttention = { [weak self] in
            // Copilot is notify-only: its approval UI remains in VS Code, so
            // reveal the island without taking keyboard focus from the IDE.
            self?.controllers.first?.setExpanded(true, takeFocus: false)
        }
        router.onCtlJump = { [weak self] ref, reply in
            Task { [weak self] in
                guard let self else { return reply("app gone") }
                let result = await self.resolver.jump(to: ref)
                reply(result.label)
            }
        }
        router.attach(to: server)
        do {
            try server.start()
        } catch {
            NSLog("aisland: socket server failed to start: \(error)")
        }

        usage.start()
        store.onSound = { [weak self] event in
            self?.sounds.play(event)
        }
        rebuildNotchControllers()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                (NSApp.delegate as? AppDelegate)?.rebuildNotchControllers()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    // MARK: - NotchActions

    func approve(_ request: PermissionRequest) {
        router.approve(request)
        sounds.play(.approved)
    }

    func deny(_ request: PermissionRequest) {
        router.deny(request)
        sounds.play(.denied)
    }

    func alwaysAllow(_ request: PermissionRequest) {
        router.alwaysAllow(request)
    }

    /// Answer an AskUserQuestion card: focus the exact pane, then type the
    /// option digit into the TUI prompt that is already showing there.
    func answer(_ question: QuestionPrompt, option: Int) {
        guard let session = store.sessions[question.sessionID] else {
            store.removeQuestion(id: question.id)
            return
        }
        let terminal = session.terminal
        let questionID = question.id
        Task { [weak self] in
            let result = await self?.resolver.jump(to: terminal)
            guard result == .exact else {
                NSLog("aisland: question answer requires exact terminal focus; got \(String(describing: result))")
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            guard await KeystrokeSender.selectOption(option) else {
                NSLog("aisland: failed to send question option \(option)")
                return
            }
            self?.store.removeQuestion(id: questionID)
        }
    }

    func jump(to session: SessionState) {
        let terminal = session.terminal
        Task {
            let result = await resolver.jump(to: terminal)
            NSLog("aisland: jump result \(String(describing: result))")
        }
    }

    func integrationIsInstalled(_ integration: NotchIntegration) -> Bool {
        switch integration {
        case .claudeCode:
            ClaudeHookInstaller(shimPath: Self.shimSymlinkPath).health() == .installed
        case .codex:
            CodexNotifyInstaller(shimPath: Self.shimSymlinkPath).health() == .installed
        case .copilot:
            CopilotHookInstaller(shimPath: Self.shimSymlinkPath).health() == .installed
        }
    }

    func installIntegration(_ integration: NotchIntegration) {
        switch integration {
        case .claudeCode: installHooks()
        case .codex: installCodexNotify()
        case .copilot: installCopilotHooks()
        }
    }

    func uninstallIntegration(_ integration: NotchIntegration) {
        switch integration {
        case .claudeCode: uninstallHooks()
        case .codex: uninstallCodexNotify()
        case .copilot: uninstallCopilotHooks()
        }
    }

    var soundsMuted: Bool { sounds.isMuted }

    func setSoundsMuted(_ muted: Bool) {
        sounds.setMuted(muted)
        if !muted { sounds.play(.approved) }
    }

    func showAgentStatus() {
        let detections = AgentDetector().scan(shimPath: Self.shimSymlinkPath)
        let lines = detections.map { detection in
            "\(detection.installed ? "●" : "○") \(detection.displayName) — \(detection.installed ? detection.integration : "not detected")"
        }
        notifyUser("Agent Status", lines.joined(separator: "\n"))
    }

    func quitApplication() {
        NSApp.terminate(nil)
    }

    private func installHooks() {
        do {
            try ensureShimSymlink()
            let installer = ClaudeHookInstaller(shimPath: Self.shimSymlinkPath)
            try installer.install()
            notifyUser("Hooks installed", "Claude Code sessions will now appear in the notch.")
        } catch {
            notifyUser("Hook install failed", "\(error)")
        }
    }

    private func uninstallHooks() {
        do {
            let installer = ClaudeHookInstaller(shimPath: Self.shimSymlinkPath)
            try installer.uninstall()
            notifyUser("Hooks removed", "Claude Code settings restored.")
        } catch {
            notifyUser("Hook uninstall failed", "\(error)")
        }
    }

    private func installCodexNotify() {
        do {
            try ensureShimSymlink()
            try CodexNotifyInstaller(shimPath: Self.shimSymlinkPath).install()
            notifyUser("Codex notify installed", "Codex turn completions will now appear in the notch.")
        } catch {
            notifyUser("Codex install failed", "\(error)")
        }
    }

    private func uninstallCodexNotify() {
        do {
            try CodexNotifyInstaller(shimPath: Self.shimSymlinkPath).uninstall()
            notifyUser("Codex notify removed", "config.toml restored.")
        } catch {
            notifyUser("Codex uninstall failed", "\(error)")
        }
    }

    private func installCopilotHooks() {
        do {
            try ensureShimSymlink()
            try CopilotHookInstaller(shimPath: Self.shimSymlinkPath).install()
            notifyUser("Copilot hooks installed", "Copilot CLI and VS Code agent sessions will now appear in the notch.")
        } catch {
            notifyUser("Copilot install failed", "\(error)")
        }
    }

    private func uninstallCopilotHooks() {
        do {
            try CopilotHookInstaller(shimPath: Self.shimSymlinkPath).uninstall()
            notifyUser("Copilot hooks removed", "Copilot settings restored.")
        } catch {
            notifyUser("Copilot uninstall failed", "\(error)")
        }
    }

    private func ensureShimSymlink() throws {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/island-shim").path
        let directory = (Self.shimSymlinkPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: Self.shimSymlinkPath)
        try FileManager.default.createSymbolicLink(
            atPath: Self.shimSymlinkPath,
            withDestinationPath: bundled
        )
    }

    private func repairLegacyShimSymlink() throws {
        let directory = (Self.legacyShimSymlinkPath as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: directory) else { return }
        try? FileManager.default.removeItem(atPath: Self.legacyShimSymlinkPath)
        try FileManager.default.createSymbolicLink(
            atPath: Self.legacyShimSymlinkPath,
            withDestinationPath: Self.shimSymlinkPath
        )
    }

    private func repairInstalledCopilotHooks() throws {
        let installer = CopilotHookInstaller(shimPath: Self.shimSymlinkPath)
        guard installer.health() != .missing else { return }
        try installer.install()
    }

    private func notifyUser(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    /// Phase 1: one island on the notched screen (or the main screen as a
    /// fallback). Phase 7 extends this to all displays / follow-focus.
    private func rebuildNotchControllers() {
        controllers.forEach { $0.close() }
        controllers.removeAll()

        let target = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        guard let screen = target else { return }
        let model = NotchViewModel(store: store)
        model.actions = self
        model.usage = usage
        controllers.append(NotchController(screen: screen, model: model))
    }
}
