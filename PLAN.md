# aisland - Native macOS AI Agent Island

## Status

This document replaces the original CopyIsland scaffold plan. It reflects the
repository as implemented on 2026-07-18 and is the working roadmap from here.

Status labels:

- **Done**: implemented and usable in the current app.
- **Partial**: a useful implementation exists, but the planned behavior is incomplete.
- **Planned**: no operational implementation yet.

## Product Goal

aisland is a local-first native macOS notch app for monitoring AI coding agents.
It should show live sessions, surface approvals and questions, jump to the exact
terminal pane, track usage, play compact sound alerts, and eventually monitor
remote sessions over SSH.

The target remains broad behavior parity with Vibe Island, implemented from
scratch without copying closed-source or incompatible licensed code. There are
no accounts, cloud services, licensing, or payment systems.

## Current Technical Baseline

### Identity and paths

- Project and product name: `aisland`
- Repository: `/Users/alfonsoortega/aisland`
- App bundle: `build/aisland.app`
- Bundle identifier: `com.aisland.app`
- Canonical shim: `~/.aisland/bin/island-shim`
- Socket: `~/Library/Application Support/aisland/island.sock`
- App support: `~/Library/Application Support/aisland/`
- Legacy compatibility: an existing `~/.copyisland/bin/island-shim` is repaired
  at app launch to forward to the canonical shim.

### Build system

The implemented build is a single Swift package, not an Xcode project with
nested local packages.

- `Package.swift` defines the app, libraries, helper, CLI, and test targets.
- `swift build` builds all products.
- `swift test` runs the headless test suite.
- `scripts/build.sh debug --run` assembles, ad-hoc signs, and launches the app.
- The bundle is not sandboxed and runs as an `LSUIElement` accessory app.
- There are currently no third-party package dependencies.

The manually assembled, consistently identified bundle is the current TCC
strategy. An Xcode project is not required unless distribution, notarization,
resource management, or signing needs make it worthwhile.

### Current project structure

```text
Package.swift
App/
  Info.plist
Sources/
  AislandApp/              App lifecycle, integration and settings actions
  IslandProtocol/          Wire envelopes, events, decisions, terminal identity
  IslandShim/              Foundation-only hook executable
  IslandCore/              Socket, router, sessions, gates, adapters, usage, sound
    ClaudeCode/
    Codex/
    Copilot/
    Sound/
    Usage/
  IslandCtl/               Development and event-injection CLI
  TerminalJump/            Terminal locator and focus implementations
  NotchUI/                 Panel, geometry, view model, cards, root view, pets
Tests/
  IslandProtocolTests/
  IslandCoreTests/
  NotchUITests/
scripts/
  build.sh
  fake-agent.sh
  render-pets.swift
```

## Implemented Architecture

### IPC and shim - Done

- Raw POSIX Unix domain socket using `AF_UNIX` and `SOCK_STREAM`.
- Socket permissions are `0600`; the app owns one socket server.
- NDJSON protocol v1 with UUID request correlation and ISO-8601 dates.
- Maximum accepted line size is 4 MiB.
- Wire types exist for `hookEvent`, `gateRequest`, `gateResponse`,
  `remoteHello`, and `ctlCommand`.
- The shim captures cwd, transcript path, TTY, process ancestry, terminal IDs,
  tmux, WezTerm, Kitty, and Zellij metadata.
- Lifecycle messages are fire-and-forget.
- Gate requests wait on the same connection for up to one hour.
- Fail-open behavior is implemented: socket, encoding, timeout, and app failures
  exit successfully without output so the agent can use its native prompt.
- Claude Code gate responses are emitted in Claude's native hook schema.

Current gaps:

- The router does not reject incompatible protocol versions.
- Socket/router/gate round trips and fail-open behavior lack integration tests.
- `remoteHello` is defined but not operational.
- Native gate output is implemented for Claude Code and Copilot CLI.

### Sessions and routing - Partial

- `SessionStore` is `@MainActor` and observable.
- Sessions are keyed by agent, native session ID, and optional host.
- State tracks cwd, terminal identity, title, status, phase, todos, and activity
  timestamps.
- Waiting sessions sort before ordinary sessions.
- Claude, Codex, and Copilot payloads update cards through their interpreters.
- Permission requests and questions are queued in memory.
- Session start, completion, permission, and question events trigger sounds.

Current gaps:

- The session reducer is coupled to the observable store rather than being a
  separate pure reducer.
- Phases currently cover working, awaiting permission, and idle only.
- Git branch/worktree, subagent depth, plan-review phase, awaiting-prompt phase,
  and ended/reaping behavior are not modeled.
- Live session state and pending requests do not survive app relaunch.
- There is no stale-session/dead-process reaper.

### Notch shell and UI - Partial

- Borderless nonactivating `NSPanel` at screen-saver level.
- Joins all Spaces and full-screen spaces without a Dock icon.
- Runtime physical-notch geometry uses safe-area and auxiliary screen regions.
- Per-model fallback geometry exists for known MacBook models.
- Notchless/external displays receive a centered virtual notch.
- The collapsed island now exactly matches the physical notch height.
- Idle width matches the notch; active sessions add side wings.
- Hover expands to a 560 x 400 panel with delayed collapse.
- Attention automatically expands the panel; approval cards prevent collapse.
- Expanded UI shows approval, question, session, todo, and usage content.
- Session cards jump to their captured terminal context.
- Approval actions support allow, deny, and persistent always-allow.
- Plan payloads and file changes have dedicated previews.
- Question options can be selected from the island and sent to the terminal.

Current gaps:

- Only one island controller is created, on the first notched or main display.
- There is no follow-focus behavior or configurable virtual-notch geometry.
- Edit previews show removed and added blocks, not a true line diff.
- Plan review has approve/deny but no feedback field.
- Only the first parsed question is surfaced; there is no multi-question pager.
- SwiftUI keyboard shortcuts depend on making the panel key; there is no global
  event-tap implementation or Option-G session switcher.
- UI and geometry have no automated tests or screenshot checks.

### Claude Code - Partial, primary integration

- Installs hooks for `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`,
  `Notification`, and gated `PreToolUse`.
- Uses a long hook timeout for human approval.
- Interprets Bash, Edit/MultiEdit, Write, plan review, todo, question, and generic
  payloads with tolerant fallbacks.
- Reads Claude permission rules and defers safe/allowed work to Claude.
- Holds eligible calls for notch approval.
- Persists aisland always-allow rules in Application Support.
- Questions fail open to Claude's TUI, then island choices jump to the terminal
  and type the selected option.
- Installer is idempotent, preserves foreign hooks, creates a backup, writes
  atomically, and records touched settings in a manifest.

Current gaps:

- Uninstall removes aisland entries but does not restore the backup byte for byte.
- Startup does not automatically self-heal installed hook contents.
- The manifest is not yet used to drive full uninstall.
- There is no onboarding or live TCC permission checker.

### Codex - Partial, notify-only

- Installs a top-level `notify` command in `~/.codex/config.toml`.
- Preserves unrelated config and creates a backup.
- Parses turn-complete notifications into session title and status.
- Codex sessions are explicitly notify-only; TUI-owned approvals are not gated.

Current gaps:

- No session-file watcher or richer lifecycle state.
- No Codex usage provider.
- Uninstall does not perform byte-identical backup restoration.

### GitHub Copilot - Partial, lifecycle + approvals

- Installs hooks for the VS Code agent in `~/.copilot/hooks/aisland.json`.
- Uses that file as the sole aisland registration and removes legacy aisland
  entries from `~/.copilot/settings.json` while preserving foreign entries.
- Interprets session, prompt, tool, stop, notification, permission, and error events.
- Gates Copilot CLI `permissionRequest` events and emits native allow/deny output.
- Reuses the existing permission cards without persistent always-allow.
- Deduplicates repeated tool-call requests and clears gates on decisions,
  disconnects, completion, cancellation, errors, and session end.

Current gaps:

- No richer task/subagent model.
- No usage provider.
- Integration behavior has not been acceptance-tested across all Copilot hosts.

### Agent abstraction and long tail - Planned

There is no shared `AgentAdapter`, `IntegrationInstaller`, capability `OptionSet`,
or declarative JSON adapter system yet. Gemini CLI, OpenCode, and Cursor Agent
are detected in the status UI but are not integrated.

### Terminal jump - Partial

`TerminalJumpResolver` ranks locators and returns typed results:
`exact`, `windowOnly`, `appOnly`, or `failed`.

Implemented exact or targeted paths:

- tmux
- iTerm2
- Terminal.app
- WezTerm
- Kitty

Implemented fallback/app-level paths:

- Zellij
- Ghostty
- Warp
- VS Code and Cursor
- generic ancestor application activation

Current gaps:

- Zellij does not select the exact pane.
- Ghostty, Warp, VS Code/Cursor, and generic paths need exact-window/pane work.
- Alacritty, Hyper, and Tabby do not have dedicated locators.
- There is no jump diagnostics UI, only CLI/result logging.
- Locators have no automated tests.

### Usage - Partial

- Polls Anthropic's OAuth usage endpoint every 120 seconds.
- Reads Claude credentials from disk or Keychain.
- Parses five-hour and seven-day utilization windows.
- Shows a compact quota strip in the expanded island header.

Current gaps:

- No JSONL transcript fallback.
- No Codex or other-agent quota providers.
- No expanded quota detail view or configurable refresh behavior.
- Failed refreshes can leave a stale snapshot visible.
- Async fetching and credential behavior lack tests.

### Sound - Partial

- `AVAudioEngine` generates square-wave PCM motifs locally.
- Sounds exist for session start, permission, approval, denial, completion, and
  questions.
- Mute is persisted with `UserDefaults` and exposed in island settings.

Current gaps:

- No sound packs or imported audio files.
- No per-event controls, volume, quiet hours, Focus integration, or silence rules.
- No `islandctl play-sound` command or audio tests.

### Pets - Done

- The island shows an animated pixel pet on a shared starfield scene.
- Four pets exist: X-wing (reference-styled art with a staged combat loop),
  flying saucer (rim-light chase), retro rocket (flame flicker and boost), and
  space cat (blink and tail swish).
- Art is authored as string pixel-art in `Sources/NotchUI/PetSprites.swift`;
  `scripts/render-pets.swift` regenerates the literals and a PNG preview.
- Each pet carries status-tinted pixels reflecting session state.
- Selection persists via `UserDefaults` (`aisland.petKind`) and is exposed as a
  preview picker in the island settings popover.
- `NotchUITests` covers art integrity, palette coverage, symmetry, and rotation.

Current gaps:

- Pets do not react to individual events (approval granted, completion) beyond
  the status tint.
- No per-pet reduced-motion variants beyond the static frame.

### Settings, displays, localization, and remote - Partial

- A gear button in the expanded island opens settings for integrations, agent
  status, sound mute, version information, and quitting the app.
- There is no menu-bar status item and no standalone settings window is planned.
- There is no persisted settings model beyond sound mute.
- There is no shortcut recorder, width/alignment control, per-agent toggle,
  follow-focus setting, or manifest-driven full uninstall UI.
- There are no string catalogs; user-facing text is English-only.
- Remote host fields and wire types exist, but there is no SSH tunnel manager,
  remote installer, handshake, reconnect loop, or end-to-end remote transport.

## Revised Delivery Plan

### Phase A - Reliability and rename cleanup - In progress

Goal: make the current local app dependable before expanding features.

- [x] Rename project, bundle, support directory, socket, and canonical shim to aisland.
- [x] Repair the canonical shim on every app launch.
- [x] Forward existing `.copyisland` shim installations to the canonical shim.
- [x] Make collapsed panel height match the measured physical notch.
- [ ] Add protocol-version validation with a fail-open gate response.
- [ ] Add socket/router/gate integration tests.
- [ ] Add an executable shim fail-open test with no app running.
- [ ] Test startup symlink migration and bundle assembly.
- [ ] Make integration health identify stale paths consistently for all agents.
- [ ] Add launch-time hook self-healing for integrations the user enabled.
- [ ] Make full uninstall restore backups and remove all aisland-owned artifacts.

Acceptance:

- Existing CopyIsland hooks produce no missing-path warnings.
- App-down, malformed-message, and timeout cases never block an agent.
- Install twice is equivalent to install once for every integration.
- Full uninstall restores fixture configurations byte for byte.

### Phase B - Approval and review depth - Partial

Goal: complete the high-value Claude workflow already exposed in the UI.

- [x] Allow, deny, and always-allow gate round trip.
- [x] Bash, Edit, Write, plan, todo, and question cards.
- [x] Click-to-jump and question-option keystrokes.
- [ ] Replace the naive file preview with a real line diff.
- [ ] Add plan feedback input and return it through the supported Claude flow.
- [ ] Parse and page multiple questions and more than four options.
- [ ] Add explicit plan-review and awaiting-prompt session phases.
- [ ] Add queued-request navigation rather than showing only the first item.
- [ ] Add a reliable approval hotkey path and click-to-focus fallback.
- [ ] Add the Option-G session switcher.
- [ ] Track subagent nesting where payloads expose it.

Acceptance:

- A real Claude session can review and approve an edit or plan from the island.
- Multi-question prompts can be completed without losing or misrouting options.
- Keyboard actions only affect the visible active request.

### Phase C - Terminal jump completion - Partial

Goal: turn app activation fallbacks into exact pane selection where possible.

- [x] Typed jump result and ranked locator architecture.
- [x] Exact/targeted iTerm2, Terminal.app, tmux, WezTerm, and Kitty paths.
- [ ] Exact Zellij pane selection.
- [ ] Improve Ghostty, Warp, VS Code/Cursor, and generic AX matching.
- [ ] Add dedicated Alacritty, Hyper, and Tabby locators where useful.
- [ ] Add diagnostics UI with captured `TerminalRef`, locator scores, and result.
- [ ] Add locator unit tests and live smoke scripts.

Acceptance:

- Each supported terminal has a documented exact/window/app capability level.
- Clicking a session focuses the correct pane in the supported exact matrix.

### Phase D - Agent platform and integrations - Partial

Goal: make agent support explicit, testable, and easy to extend.

- [ ] Introduce `AgentAdapter`, `IntegrationInstaller`, and capability flags.
- [ ] Move Claude, Codex, and Copilot behind those shared contracts.
- [ ] Add manifest-backed integration ownership and self-heal state.
- [ ] Add Codex session-file watching for richer lifecycle state.
- [ ] Add Gemini CLI integration.
- [ ] Add declarative adapter specs for compatible long-tail agents.
- [ ] Show capability degradation clearly in agent status/settings UI.

Acceptance:

- Every adapter declares whether it supports live status, gating, plan review,
  questions, usage, and subagents.
- Adding a notify-style agent does not require modifying session routing internals.

### Phase E - Settings and multi-display - Partial

Goal: make the app configurable and correct across real display setups.

- [x] Add in-island settings for integrations, status, mute, and Quit.
- [ ] Add a persisted settings model behind the in-island controls.
- [ ] Add virtual-notch width and alignment controls with live preview.
- [ ] Add one-panel-per-screen and follow-focus modes.
- [ ] Add shortcut recording and conflict display.
- [ ] Add per-agent enable/disable controls and integration health actions.
- [ ] Add full uninstall driven by the installation manifest.
- [ ] Add onboarding for Accessibility and Apple Events with live TCC status.
- [ ] Add string catalogs after settings and primary UI copy stabilize.

Acceptance:

- Physical, external, mirrored, and changing display configurations remain aligned.
- Users can inspect and repair integrations without editing config files.

### Phase F - Usage and sound completion - Partial

Goal: make existing quota and audio features robust and configurable.

- [ ] Add incremental Claude transcript JSONL usage fallback.
- [ ] Add Codex usage when reliable local/account data is available.
- [ ] Add expanded quota details and stale/error states.
- [ ] Add per-event sound controls, volume, quiet hours, and Focus behavior.
- [ ] Add local sound-pack import.
- [ ] Add `islandctl play-sound` and usage fixture tests.

Acceptance:

- Claude usage remains useful when the OAuth endpoint or credentials are unavailable.
- Sound policy is deterministic and testable from mute through Focus/quiet-hours gates.

### Phase G - Remote SSH - Planned

Goal: monitor and gate sessions on configured remote hosts without a cloud service.

- [ ] Choose and document the remote socket forwarding topology.
- [ ] Send and handle `remoteHello` with host identity.
- [ ] Add SSH config alias support, ProxyJump compatibility, and reconnect backoff.
- [ ] Add remote shim installation for supported platforms.
- [ ] Tag, display, and route remote sessions by host.
- [ ] Preserve fail-open behavior across tunnel loss.
- [ ] Verify install, tunnel, lifecycle, and gate round trip via `ssh localhost`.

### Phase H - Polish and distribution - Planned

Goal: make aisland stable enough for daily use and distribution.

- [ ] Add stale/dead session reaping and local idle/away summaries.
- [ ] Coalesce high-frequency events and profile 10 concurrent sessions.
- [ ] Target less than 100 MiB RSS under the acceptance workload.
- [ ] Add UI regression checks for physical and virtual notch geometry.
- [ ] Add CI for debug build and tests.
- [ ] Add app icon, release metadata, archive/export, and notarization workflow.
- [ ] Add a user-facing README and troubleshooting guide.

## Verification Harness

Current commands:

```sh
swift build
swift test
scripts/build.sh debug --run
scripts/fake-agent.sh
.build/debug/islandctl jump --delay 2
```

Existing automated coverage includes:

- Wire codec and terminal identity capture.
- Basic session lifecycle and agent/session key isolation.
- Claude interpretation, permission rules, and hook installation.
- Codex and Copilot installer/interpreter behavior.
- Usage response parsing.

Next cross-cutting test priorities:

1. Real socket and gate round trips using the production shim.
2. Fail-open behavior with no server, malformed data, and disconnects.
3. Installer migration, self-heal, and byte-identical uninstall fixtures.
4. Terminal locator ranking and command-generation tests.
5. Notch geometry tests for physical, virtual, and multi-display cases.
6. Recorded event timeline replay for UI review.

## Top Risks

1. **Fail-open gates**: a crash, timeout, malformed message, or lost tunnel must
   never block the agent. This needs integration coverage, not only code review.
2. **TCC stability**: Accessibility and Apple Events grants depend on stable app
   identity and signing. Packaging changes must preserve that identity.
3. **Keyboard handling**: a nonactivating panel must not steal focus or route a
   shortcut to the wrong request.
4. **Agent config ownership**: installers must preserve unrelated settings,
   migrate renamed paths, and support trustworthy full uninstall.
5. **Terminal precision**: process ancestry and terminal APIs vary; capability
   levels and diagnostics must make fallbacks visible.
6. **Undocumented account data**: usage endpoints and Focus state require local
   fallbacks and explicit stale/error states.
7. **Remote failure modes**: SSH reconnect and tunnel loss must preserve local
   security and fail-open semantics.