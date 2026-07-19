import XCTest
@testable import IslandCore
import IslandProtocol

final class PermissionOracleTests: XCTestCase {
    func testSafeToolsAlwaysDefer() {
        let oracle = PermissionOracle(allowPatterns: [])
        XCTAssertEqual(oracle.verdict(toolName: "Read", primaryArgument: "/etc/hosts"), .defer_)
        XCTAssertEqual(oracle.verdict(toolName: "Grep", primaryArgument: "foo"), .defer_)
    }

    func testUnknownToolHolds() {
        let oracle = PermissionOracle(allowPatterns: [])
        XCTAssertEqual(oracle.verdict(toolName: "Bash", primaryArgument: "rm -rf /"), .hold)
        XCTAssertEqual(oracle.verdict(toolName: "Edit", primaryArgument: "/tmp/a.txt"), .hold)
    }

    func testBareToolRuleAllowsEverything() {
        let oracle = PermissionOracle(allowPatterns: ["Bash"])
        XCTAssertEqual(oracle.verdict(toolName: "Bash", primaryArgument: "anything at all"), .defer_)
    }

    func testPrefixRule() {
        let oracle = PermissionOracle(allowPatterns: ["Bash(git status:*)", "Bash(npm run *)"])
        XCTAssertEqual(oracle.verdict(toolName: "Bash", primaryArgument: "git status --short"), .defer_)
        XCTAssertEqual(oracle.verdict(toolName: "Bash", primaryArgument: "npm run lint"), .defer_)
        XCTAssertEqual(oracle.verdict(toolName: "Bash", primaryArgument: "git push"), .hold)
    }

    func testExactRule() {
        let oracle = PermissionOracle(allowPatterns: ["Bash(npm test)"])
        XCTAssertEqual(oracle.verdict(toolName: "Bash", primaryArgument: "npm test"), .defer_)
        XCTAssertEqual(oracle.verdict(toolName: "Bash", primaryArgument: "npm test --watch"), .hold)
    }

    func testMalformedPatternNeverAllows() {
        let oracle = PermissionOracle(allowPatterns: ["Bash(unclosed", ""])
        XCTAssertEqual(oracle.verdict(toolName: "Bash", primaryArgument: "ls"), .hold)
    }

    func testBypassAndPlanModesAlwaysDefer() {
        let oracle = PermissionOracle(allowPatterns: [])
        XCTAssertEqual(oracle.verdict(toolName: "Bash", primaryArgument: "rm -rf /", permissionMode: .bypassPermissions), .defer_)
        XCTAssertEqual(oracle.verdict(toolName: "mcp__unknown", primaryArgument: nil, permissionMode: .plan), .defer_)
        XCTAssertEqual(oracle.verdict(toolName: "Bash", primaryArgument: "git push", permissionMode: .auto), .defer_)
        XCTAssertEqual(oracle.verdict(toolName: "Bash", primaryArgument: "git push", permissionMode: .dontAsk), .defer_)
    }

    func testDenyAndAskTakePrecedenceOverAllow() {
        let oracle = PermissionOracle(
            allowPatterns: ["Bash(git *)"],
            denyPatterns: ["Bash(git push *)"],
            askPatterns: ["Bash(git status *)"]
        )
        XCTAssertEqual(oracle.verdict(toolName: "Bash", primaryArgument: "git push origin main"), .defer_)
        XCTAssertEqual(
            oracle.verdict(toolName: "Bash", primaryArgument: "git status --short"),
            .holdWithoutStoredApproval
        )
        XCTAssertEqual(oracle.verdict(toolName: "Bash", primaryArgument: "git fetch"), .defer_)
    }

    func testAcceptEditsDefersEditsButStillHoldsBash() {
        let oracle = PermissionOracle(allowPatterns: [])
        for tool in ["Edit", "MultiEdit", "Write", "NotebookEdit"] {
            XCTAssertEqual(oracle.verdict(toolName: tool, primaryArgument: "/tmp/a", permissionMode: .acceptEdits), .defer_)
        }
        XCTAssertEqual(oracle.verdict(toolName: "Bash", primaryArgument: "git push", permissionMode: .acceptEdits), .hold)
    }

    func testSettingsDefaultModeAndPayloadOverride() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oracle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data(#"{"permissions":{"defaultMode":"bypassPermissions"}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude/settings.json"))

        let oracle = PermissionOracle.loadForProject(cwd: home.path, home: home.path)
        XCTAssertEqual(oracle.verdict(toolName: "Bash", primaryArgument: "git push"), .defer_)
        XCTAssertEqual(oracle.verdict(toolName: "Bash", primaryArgument: "git push", permissionMode: .default), .hold)
    }

    func testLoadsRulesFromRepositoryRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oracle-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let nested = root.appendingPathComponent("Sources/Feature")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(#"{"permissions":{"deny":["Bash(rm *)"],"ask":["Bash(git push *)"],"defaultMode":"manual"}}"#.utf8)
            .write(to: root.appendingPathComponent(".claude/settings.json"))

        let oracle = PermissionOracle.loadForProject(cwd: nested.path, home: root.appendingPathComponent("home").path)
        XCTAssertEqual(oracle.verdict(toolName: "Bash", primaryArgument: "rm file"), .defer_)
        XCTAssertEqual(
            oracle.verdict(toolName: "Bash", primaryArgument: "git push origin main"),
            .holdWithoutStoredApproval
        )
        XCTAssertEqual(oracle.verdict(toolName: "Bash", primaryArgument: "make deploy"), .hold)
    }
}

final class ClaudeCodeInterpreterTests: XCTestCase {
    func testBashToolCall() throws {
        let payload = Data(#"{"tool_name":"Bash","permission_mode":"bypassPermissions","tool_input":{"command":"npm test"}}"#.utf8)
        let call = try XCTUnwrap(ClaudeCodeInterpreter.toolCall(fromPayload: payload))
        XCTAssertEqual(call.name, "Bash")
        XCTAssertEqual(call.primaryArgument, "npm test")
        XCTAssertEqual(call.summary, "npm test")
        XCTAssertEqual(call.permissionMode, .bypassPermissions)
    }

    func testEditToolCall() throws {
        let payload = Data(#"{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x.swift","old_string":"a"}}"#.utf8)
        let call = try XCTUnwrap(ClaudeCodeInterpreter.toolCall(fromPayload: payload))
        XCTAssertEqual(call.primaryArgument, "/tmp/x.swift")
    }

    func testNonToolPayloadReturnsNil() {
        XCTAssertNil(ClaudeCodeInterpreter.toolCall(fromPayload: Data(#"{"prompt":"hi"}"#.utf8)))
        XCTAssertNil(ClaudeCodeInterpreter.toolCall(fromPayload: Data("not json".utf8)))
    }

    func testStatusLines() {
        XCTAssertEqual(
            ClaudeCodeInterpreter.statusLine(event: "UserPromptSubmit", payload: Data(#"{"prompt":"fix\nthe bug"}"#.utf8)),
            "You: fix the bug"
        )
        XCTAssertEqual(
            ClaudeCodeInterpreter.statusLine(event: "Stop", payload: Data("{}".utf8)),
            "Done — click to jump"
        )
        XCTAssertNil(ClaudeCodeInterpreter.statusLine(event: "PostToolUse", payload: Data("{}".utf8)))
    }
}

final class IslandRouterPermissionModeTests: XCTestCase {
    @MainActor
    func testBypassPayloadRespondsAskWithoutRegisteringCard() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { close(descriptors[1]) }

        let queue = DispatchQueue(label: "IslandRouterPermissionModeTests")
        let connection = SocketConnection(fd: descriptors[0], queue: queue)
        let gates = GateCenter()
        let store = SessionStore()
        let rulesPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("rules-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: rulesPath) }
        let router = IslandRouter(store: store, gates: gates, rules: ApprovalRulesStore(path: rulesPath))
        let payload = Data(#"{"tool_name":"Bash","permission_mode":"bypassPermissions","tool_input":{"command":"rm -rf /tmp/example"}}"#.utf8)
        let event = HookEvent(
            agent: "claude-code",
            event: "PreToolUse",
            sessionID: "bypass-session",
            cwd: "/tmp",
            terminal: TerminalRef(),
            payload: payload
        )
        let line = try WireCodec.encodeLine(Envelope(type: .gateRequest, body: event))

        router.handle(line: Data(line.dropLast()), connection: connection)

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(descriptors[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = read(descriptors[1], &bytes, bytes.count)
        XCTAssertGreaterThan(count, 0)
        let response = try WireCodec.decode(GateResponse.self, from: Data(bytes.prefix(Int(count) - 1)))
        XCTAssertEqual(response.body.decision, .ask)
        XCTAssertTrue(gates.pendingIDs.isEmpty)
        XCTAssertTrue(store.requests.isEmpty)
    }

    @MainActor
    func testDenyRuleWinsOverStoredApproval() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { close(descriptors[1]) }

        let connection = SocketConnection(fd: descriptors[0], queue: DispatchQueue(label: "deny-rule-test"))
        let rulesPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("rules-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: rulesPath) }
        let rules = ApprovalRulesStore(path: rulesPath)
        try rules.addRule(toolName: "Bash", primaryArgument: "rm file")
        let gates = GateCenter()
        let store = SessionStore()
        let router = IslandRouter(store: store, gates: gates, rules: rules)
        router.oracleProvider = { _ in
            PermissionOracle(allowPatterns: [], denyPatterns: ["Bash(rm *)"])
        }
        let payload = Data(#"{"tool_name":"Bash","tool_input":{"command":"rm file"}}"#.utf8)
        let event = HookEvent(
            agent: "claude-code", event: "PreToolUse", sessionID: "deny-session",
            cwd: "/tmp", terminal: TerminalRef(), payload: payload
        )
        let line = try WireCodec.encodeLine(Envelope(type: .gateRequest, body: event))

        router.handle(line: Data(line.dropLast()), connection: connection)

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(descriptors[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = read(descriptors[1], &bytes, bytes.count)
        XCTAssertGreaterThan(count, 0)
        let response = try WireCodec.decode(GateResponse.self, from: Data(bytes.prefix(Int(count) - 1)))
        XCTAssertEqual(response.body.decision, .ask)
        XCTAssertTrue(store.requests.isEmpty)
    }
}

final class Phase2ParsingTests: XCTestCase {
    func testEditDetails() throws {
        let payload = Data(#"{"tool_name":"Edit","tool_input":{"file_path":"/a.ts","old_string":"x","new_string":"y"}}"#.utf8)
        let call = try XCTUnwrap(ClaudeCodeInterpreter.toolCall(fromPayload: payload))
        XCTAssertEqual(call.details, .fileEdit(path: "/a.ts", old: "x", new: "y"))
    }

    func testPlanDetails() throws {
        let payload = Data("{\"tool_name\":\"ExitPlanMode\",\"tool_input\":{\"plan\":\"## Do it\"}}".utf8)
        let call = try XCTUnwrap(ClaudeCodeInterpreter.toolCall(fromPayload: payload))
        XCTAssertEqual(call.details, .plan(markdown: "## Do it"))
        XCTAssertTrue(PermissionRequest(
            id: UUID(), sessionID: SessionID(agent: "claude-code", raw: "s"),
            toolName: call.name, summary: call.summary, details: call.details
        ).isPlanReview)
    }

    func testQuestionParsing() throws {
        let payload = Data("""
        {"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which target?","options":[{"label":"Prod"},{"label":"Staging"}]}]}}
        """.utf8)
        let question = try XCTUnwrap(ClaudeCodeInterpreter.question(fromPayload: payload))
        XCTAssertEqual(question.question, "Which target?")
        XCTAssertEqual(question.options, ["Prod", "Staging"])
        XCTAssertNil(ClaudeCodeInterpreter.question(fromPayload: Data(#"{"tool_name":"Bash"}"#.utf8)))
    }

    func testTodoParsing() throws {
        let payload = Data("""
        {"tool_name":"TodoWrite","tool_input":{"todos":[{"content":"a","status":"completed"},{"content":"b","status":"in_progress"}]}}
        """.utf8)
        let todos = try XCTUnwrap(ClaudeCodeInterpreter.todos(fromPayload: payload))
        XCTAssertEqual(todos.count, 2)
        XCTAssertEqual(todos[0].status, .completed)
        XCTAssertEqual(todos[1].status, .inProgress)
    }
}

final class ApprovalRulesStoreTests: XCTestCase {
    @MainActor
    func testRulePersistenceAndMatching() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("rules-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = ApprovalRulesStore(path: path)
        XCTAssertFalse(store.allows(toolName: "Bash", primaryArgument: "git push"))

        try store.addRule(toolName: "Bash", primaryArgument: "git push origin main")
        XCTAssertTrue(store.allows(toolName: "Bash", primaryArgument: "git push origin main"))
        XCTAssertFalse(store.allows(toolName: "Bash", primaryArgument: "git status"))
        XCTAssertFalse(store.allows(toolName: "Bash", primaryArgument: "npm test"))

        try store.addRule(toolName: "WebFetch", primaryArgument: "https://x.test")
        XCTAssertTrue(store.allows(toolName: "WebFetch", primaryArgument: "https://x.test"))
        XCTAssertFalse(store.allows(toolName: "WebFetch", primaryArgument: "https://other.test"))

        // Reload from disk.
        let reloaded = ApprovalRulesStore(path: path)
        XCTAssertTrue(reloaded.allows(toolName: "Bash", primaryArgument: "git push origin main"))
        XCTAssertFalse(reloaded.allows(toolName: "Bash", primaryArgument: "git status"))
        XCTAssertEqual(
            reloaded.patterns.sorted(),
            ["Bash(git push origin main)", "WebFetch(https://x.test)"]
        )
    }

    @MainActor
    func testWriteFailureDoesNotInstallRuleInMemory() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("rules-parent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("not a directory".utf8).write(to: parent)
        let store = ApprovalRulesStore(path: parent.appendingPathComponent("rules.json").path)

        XCTAssertThrowsError(try store.addRule(toolName: "Bash", primaryArgument: "git push"))
        XCTAssertFalse(store.allows(toolName: "Bash", primaryArgument: "git push"))
        XCTAssertTrue(store.patterns.isEmpty)
    }
}

final class GateCenterTests: XCTestCase {
    @MainActor
    func testAlreadyClosedConnectionAbortsNewGate() async {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { close(descriptors[1]) }

        let queue = DispatchQueue(label: "GateCenterTests")
        let connection = SocketConnection(fd: descriptors[0], queue: queue)
        connection.start()
        connection.close()
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }

        let aborted = expectation(description: "closed gate removed")
        let gates = GateCenter()
        gates.onGateAborted = { _ in aborted.fulfill() }
        gates.register(id: UUID(), connection: connection)

        await fulfillment(of: [aborted], timeout: 1)
        XCTAssertTrue(gates.pendingIDs.isEmpty)
    }
}

final class CopilotAdapterTests: XCTestCase {
    func testInstallBothSurfacesIdempotentAndPreserving() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let hooksDirectory = dir + "/hooks"
        try FileManager.default.createDirectory(atPath: hooksDirectory, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: URL(fileURLWithPath: hooksDirectory + "/copyisland.json"))
        // Foreign/Vibe hooks survive; legacy aisland entries are removed.
        let seed = #"{"version":1,"hooks":{"agentStop":[{"type":"command","bash":"/other/tool --event agentStop","timeoutSec":10}],"permissionRequest":[{"type":"command","bash":"/Users/me/.vibe-island/bin/bridge","timeoutSec":10},{"type":"command","bash":"/old/island-shim copilot permissionRequest","timeoutSec":10}]}}"#
        try Data(seed.utf8).write(to: URL(fileURLWithPath: dir + "/settings.json"))

        let installer = CopilotHookInstaller(copilotDirectory: dir, shimPath: "/fake/island-shim")
        XCTAssertEqual(installer.health(), .partial)
        try installer.install()
        XCTAssertEqual(installer.health(), .installed)
        let once = try String(contentsOfFile: dir + "/settings.json", encoding: .utf8)
        try installer.install()
        let twice = try String(contentsOfFile: dir + "/settings.json", encoding: .utf8)
        XCTAssertEqual(once, twice, "double install must not duplicate")
        XCTAssertTrue(once.contains("/other/tool"), "foreign entries preserved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/hooks/aisland.json"))

        // Hook file is the sole aisland registration; only permissionRequest gates.
        let hookData = try XCTUnwrap(FileManager.default.contents(atPath: dir + "/hooks/aisland.json"))
        let hookJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: hookData) as? [String: Any])
        let hooks = try XCTUnwrap(hookJSON["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["preToolUse"])
        XCTAssertNotNil(hooks["agentStop"])
        XCTAssertNotNil(hooks["sessionEnd"])
        XCTAssertNotNil(hooks["subagentStart"])
        XCTAssertNotNil(hooks["permissionRequest"])
        XCTAssertNil(hooks["PermissionRequest"])
        XCTAssertEqual(hookJSON["version"] as? Int, 1)
        for (event, value) in hooks {
            let entries = value as? [[String: Any]] ?? []
            XCTAssertTrue(entries.allSatisfy { ($0["command"] as? String)?.contains("exit 0") == true })
            XCTAssertEqual(entries.first?["timeoutSec"] as? Int, event == "permissionRequest" ? 3600 : 10)
            XCTAssertEqual(
                (entries.first?["command"] as? String)?.contains("--gate"),
                event == "permissionRequest"
            )
        }
        let settingsData = try XCTUnwrap(FileManager.default.contents(atPath: dir + "/settings.json"))
        let settingsJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: settingsData) as? [String: Any])
        let settingsHooks = try XCTUnwrap(settingsJSON["hooks"] as? [String: Any])
        let cliPermissionEntries = try XCTUnwrap(settingsHooks["permissionRequest"] as? [[String: Any]])
        XCTAssertEqual(cliPermissionEntries.count, 1)
        XCTAssertTrue((cliPermissionEntries[0]["bash"] as? String)?.contains(".vibe-island") == true)
        XCTAssertFalse(try String(contentsOfFile: dir + "/settings.json", encoding: .utf8).contains("island-shim"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksDirectory + "/copyisland.json"))

        try installer.uninstall()
        XCTAssertEqual(installer.health(), .missing)
        let final = try String(contentsOfFile: dir + "/settings.json", encoding: .utf8)
        XCTAssertTrue(final.contains("/other/tool"), "foreign entries survive uninstall")
        XCTAssertFalse(final.contains("island-shim"))
    }

    func testPermissionRequestParsing() throws {
        let sessionID = SessionID(agent: "copilot", raw: "s1")
        let shell = try XCTUnwrap(CopilotInterpreter.permissionRequest(
            id: UUID(),
            sessionID: sessionID,
            payload: Data(#"{"sessionId":"s1","toolCallId":"call-1","toolName":"bash","toolInput":{"command":"npm test"}}"#.utf8)
        ))
        XCTAssertEqual(shell.summary, "npm test")
        XCTAssertEqual(shell.details, .bash(command: "npm test"))
        XCTAssertEqual(shell.deduplicationKey, "call-1")
        XCTAssertFalse(shell.canAlwaysAllow)

        let edit = try XCTUnwrap(CopilotInterpreter.permissionRequest(
            id: UUID(),
            sessionID: sessionID,
            payload: Data(#"{"toolName":"edit","toolInput":"{\"filePath\":\"/tmp/a.swift\",\"oldString\":\"a\",\"newString\":\"b\"}"}"#.utf8)
        ))
        XCTAssertEqual(edit.details, .fileEdit(path: "/tmp/a.swift", old: "a", new: "b"))

        let write = try XCTUnwrap(CopilotInterpreter.permissionRequest(
            id: UUID(),
            sessionID: sessionID,
            payload: Data(#"{"tool_name":"create","tool_input":{"path":"/tmp/new.txt","content":"hello"}}"#.utf8)
        ))
        XCTAssertEqual(write.details, .fileWrite(path: "/tmp/new.txt", content: "hello"))

        let web = try XCTUnwrap(CopilotInterpreter.permissionRequest(
            id: UUID(),
            sessionID: sessionID,
            payload: Data(#"{"toolName":"web_fetch","toolInput":{"url":"https://example.com"}}"#.utf8)
        ))
        XCTAssertEqual(web.summary, "https://example.com")
    }

    func testNativePermissionResponseSchemas() throws {
        let allowData = try XCTUnwrap(NativeGateOutput.encode(
            agent: "copilot",
            event: "permissionRequest",
            response: GateResponse(decision: .allow)
        ))
        let allow = try XCTUnwrap(JSONSerialization.jsonObject(with: allowData) as? [String: String])
        XCTAssertEqual(allow, ["behavior": "allow"])

        let denyData = try XCTUnwrap(NativeGateOutput.encode(
            agent: "copilot",
            event: "permissionRequest",
            response: GateResponse(decision: .deny, reason: "No")
        ))
        let deny = try XCTUnwrap(JSONSerialization.jsonObject(with: denyData) as? [String: String])
        XCTAssertEqual(deny, ["behavior": "deny", "message": "No"])
        XCTAssertNil(try NativeGateOutput.encode(
            agent: "copilot",
            event: "permissionRequest",
            response: GateResponse(decision: .ask)
        ))
    }

    func testShimFailsOpenWhenAppUnavailable() throws {
        let shim = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/island-shim")
        guard FileManager.default.isExecutableFile(atPath: shim.path) else {
            throw XCTSkip("island-shim was not built")
        }
        let process = Process()
        process.executableURL = shim
        process.arguments = ["copilot", "permissionRequest", "--gate"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "ISLAND_SOCKET": FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-\(UUID().uuidString).sock").path,
        ]) { _, new in new }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"toolName":"bash","toolInput":{"command":"true"}}"#.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }

    func testInterpreterEventMapping() {
        let stop = CopilotInterpreter.update(event: "agentStop", payload: Data("{}".utf8))
        XCTAssertTrue(stop.idle)
        let prompt = CopilotInterpreter.update(
            event: "UserPromptSubmit",
            payload: Data(#"{"prompt":"add dark mode"}"#.utf8)
        )
        XCTAssertEqual(prompt.title, "add dark mode")
        XCTAssertFalse(prompt.idle)
        let permission = CopilotInterpreter.update(event: "permissionRequest", payload: Data("{}".utf8))
        XCTAssertEqual(permission.statusLine, "⚠ Needs approval in terminal")
        XCTAssertTrue(permission.needsAttention)
        XCTAssertFalse(permission.resolvesAttention)

        let nestedPermission = CopilotInterpreter.update(
            event: "PermissionRequest",
            payload: Data(#"{"input":{"arguments":{"tool_input":{"toolName":"terminal"}}}}"#.utf8)
        )
        XCTAssertEqual(nestedPermission.statusLine, "⚠ Needs approval for terminal")
        XCTAssertTrue(nestedPermission.needsAttention)

        let permissionNotification = CopilotInterpreter.update(
            event: "notification",
            payload: Data(#"{"notification_type":"permission_prompt","message":"Edit file"}"#.utf8)
        )
        XCTAssertTrue(permissionNotification.needsAttention)
        XCTAssertFalse(permissionNotification.resolvesAttention)

        let realVSCodeTool = CopilotInterpreter.update(
            event: "PostToolUse",
            payload: Data(#"{"sessionId":"s1","cwd":"/tmp/project","toolName":"bash","toolArgs":"{}"}"#.utf8)
        )
        XCTAssertEqual(realVSCodeTool.statusLine, "Finished bash")

        let nestedPrompt = CopilotInterpreter.update(
            event: "userPromptSubmitted",
            payload: Data(#"{"input":{"sessionId":"s1","userPrompt":"fix the login flow"}}"#.utf8)
        )
        XCTAssertEqual(nestedPrompt.title, "fix the login flow")

        let subagentStop = CopilotInterpreter.update(event: "SubagentStop", payload: Data("{}".utf8))
        XCTAssertEqual(subagentStop.statusLine, "Subagent finished")
        XCTAssertFalse(subagentStop.idle)
    }
}

final class CopilotGateTests: XCTestCase {
    private func connectionPair(label: String) throws -> (SocketConnection, Int32, DispatchQueue) {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let queue = DispatchQueue(label: label)
        return (SocketConnection(fd: descriptors[0], queue: queue), descriptors[1], queue)
    }

    private func line(
        type: WireType,
        id: UUID = UUID(),
        event: String,
        sessionID: String = "copilot-session",
        payload: String
    ) throws -> Data {
        let hook = HookEvent(
            agent: "copilot",
            event: event,
            sessionID: sessionID,
            cwd: "/tmp/project",
            terminal: TerminalRef(termProgram: "vscode"),
            payload: Data(payload.utf8)
        )
        return Data(try WireCodec.encodeLine(Envelope(id: id, type: type, body: hook)).dropLast())
    }

    private func readResponse(from fd: Int32) throws -> GateResponse {
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &bytes, bytes.count)
        XCTAssertGreaterThan(count, 0)
        return try WireCodec.decode(
            GateResponse.self,
            from: Data(bytes.prefix(Int(count) - 1))
        ).body
    }

    @MainActor
    func testPermissionNotificationSequenceStaysPendingThenApproves() throws {
        let (connection, peer, _) = try connectionPair(label: "CopilotGateTests.approve")
        defer { close(peer) }
        let rulesPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("rules-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: rulesPath) }
        let store = SessionStore()
        let gates = GateCenter()
        let router = IslandRouter(store: store, gates: gates, rules: ApprovalRulesStore(path: rulesPath))
        let requestID = UUID()
        let requestPayload = #"{"sessionId":"copilot-session","toolCallId":"call-1","toolName":"edit","toolInput":{"filePath":"/tmp/a.swift","oldString":"a","newString":"b"}}"#

        router.handle(
            line: try line(type: .gateRequest, id: requestID, event: "permissionRequest", payload: requestPayload),
            connection: connection
        )
        XCTAssertEqual(store.requests.count, 1)
        XCTAssertEqual(store.firstRequest?.details, .fileEdit(path: "/tmp/a.swift", old: "a", new: "b"))
        XCTAssertFalse(store.firstRequest?.canAlwaysAllow ?? true)

        let (notificationConnection, notificationPeer, _) = try connectionPair(label: "CopilotGateTests.notification")
        defer {
            notificationConnection.close()
            close(notificationPeer)
        }
        router.handle(
            line: try line(
                type: .hookEvent,
                event: "notification",
                payload: #"{"notification_type":"permission_prompt","message":"Edit file"}"#
            ),
            connection: notificationConnection
        )
        XCTAssertEqual(store.requests.count, 1)
        XCTAssertEqual(store.sessions[SessionID(agent: "copilot", raw: "copilot-session")]?.phase, .awaitingPermission)

        router.approve(try XCTUnwrap(store.firstRequest))
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertEqual(try readResponse(from: peer).decision, .allow)
    }

    @MainActor
    func testToolCompletionOnlyClearsMatchingPermission() throws {
        let first = try connectionPair(label: "CopilotGateTests.completion.first")
        let second = try connectionPair(label: "CopilotGateTests.completion.second")
        let lifecycle = try connectionPair(label: "CopilotGateTests.completion.lifecycle")
        defer {
            close(first.1)
            second.0.close()
            close(second.1)
            lifecycle.0.close()
            close(lifecycle.1)
        }
        let rulesPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("rules-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: rulesPath) }
        let store = SessionStore()
        let gates = GateCenter()
        let router = IslandRouter(store: store, gates: gates, rules: ApprovalRulesStore(path: rulesPath))
        let firstID = UUID()
        let secondID = UUID()

        router.handle(
            line: try line(
                type: .gateRequest,
                id: firstID,
                event: "permissionRequest",
                payload: #"{"toolCallId":"call-1","toolName":"bash","toolInput":{"command":"echo first"}}"#
            ),
            connection: first.0
        )
        router.handle(
            line: try line(
                type: .gateRequest,
                id: secondID,
                event: "permissionRequest",
                payload: #"{"toolCallId":"call-2","toolName":"bash","toolInput":{"command":"echo second"}}"#
            ),
            connection: second.0
        )
        router.handle(
            line: try line(
                type: .hookEvent,
                event: "postToolUse",
                payload: #"{"toolCallId":"call-1","toolName":"bash"}"#
            ),
            connection: lifecycle.0
        )

        XCTAssertEqual(try readResponse(from: first.1).decision, .ask)
        XCTAssertEqual(store.requests.map(\.id), [secondID])
        XCTAssertEqual(gates.pendingIDs, [secondID])
    }

    @MainActor
    func testDuplicateRequestsShareOneCardAndDecision() throws {
        let first = try connectionPair(label: "CopilotGateTests.duplicate.first")
        let second = try connectionPair(label: "CopilotGateTests.duplicate.second")
        defer {
            close(first.1)
            close(second.1)
        }
        let rulesPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("rules-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: rulesPath) }
        let store = SessionStore()
        let gates = GateCenter()
        let router = IslandRouter(store: store, gates: gates, rules: ApprovalRulesStore(path: rulesPath))
        let payload = #"{"toolCallId":"same-call","toolName":"bash","toolInput":{"command":"rm file"}}"#

        router.handle(
            line: try line(type: .gateRequest, event: "permissionRequest", payload: payload),
            connection: first.0
        )
        router.handle(
            line: try line(type: .gateRequest, event: "permissionRequest", payload: payload),
            connection: second.0
        )
        XCTAssertEqual(store.requests.count, 1)
        XCTAssertEqual(gates.pendingIDs.count, 2)

        router.deny(try XCTUnwrap(store.firstRequest))
        XCTAssertEqual(try readResponse(from: first.1).decision, .deny)
        XCTAssertEqual(try readResponse(from: second.1).decision, .deny)
        XCTAssertTrue(gates.pendingIDs.isEmpty)
    }

    @MainActor
    func testStopClearsStaleRequestAndDefersGate() throws {
        let gate = try connectionPair(label: "CopilotGateTests.stop.gate")
        let lifecycle = try connectionPair(label: "CopilotGateTests.stop.lifecycle")
        defer {
            close(gate.1)
            lifecycle.0.close()
            close(lifecycle.1)
        }
        let rulesPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("rules-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: rulesPath) }
        let store = SessionStore()
        let gates = GateCenter()
        let router = IslandRouter(store: store, gates: gates, rules: ApprovalRulesStore(path: rulesPath))

        router.handle(
            line: try line(
                type: .gateRequest,
                event: "permissionRequest",
                payload: #"{"toolName":"bash","toolInput":{"command":"npm test"}}"#
            ),
            connection: gate.0
        )
        router.handle(
            line: try line(type: .hookEvent, event: "agentStop", payload: "{}"),
            connection: lifecycle.0
        )

        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertEqual(try readResponse(from: gate.1).decision, .ask)
    }

    @MainActor
    func testDisconnectRemovesStaleRequest() async throws {
        let gate = try connectionPair(label: "CopilotGateTests.disconnect")
        defer { close(gate.1) }
        let rulesPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("rules-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: rulesPath) }
        let store = SessionStore()
        let gates = GateCenter()
        let router = IslandRouter(store: store, gates: gates, rules: ApprovalRulesStore(path: rulesPath))
        router.handle(
            line: try line(
                type: .gateRequest,
                event: "permissionRequest",
                payload: #"{"toolName":"bash","toolInput":{"command":"npm test"}}"#
            ),
            connection: gate.0
        )
        XCTAssertEqual(store.requests.count, 1)

        gate.0.close()
        await withCheckedContinuation { continuation in
            gate.2.async { continuation.resume() }
        }
        for _ in 0..<20 where !store.requests.isEmpty {
            await Task.yield()
        }
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertTrue(gates.pendingIDs.isEmpty)
    }
}

final class UsageParserTests: XCTestCase {
    func testParsePercentAndCountdown() throws {
        let resets = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 3600 + 59 * 60 + 30))
        let json = #"{"five_hour":{"utilization":11,"resets_at":"\#(resets)"},"seven_day":{"utilization":2}}"#
        let snapshot = try XCTUnwrap(UsageParser.parse(Data(json.utf8)))
        XCTAssertEqual(snapshot.fiveHour?.utilization, 11)
        XCTAssertEqual(snapshot.sevenDay?.utilization, 2)
        let strip = try XCTUnwrap(snapshot.stripText)
        XCTAssertTrue(strip.hasPrefix("5h 11% · 3h59m"), "got: \(strip)")
        XCTAssertTrue(strip.contains("7d 2%"))
    }

    func testParseFractionUtilization() throws {
        let snapshot = try XCTUnwrap(UsageParser.parse(Data(#"{"five_hour":{"utilization":0.42}}"#.utf8)))
        XCTAssertEqual(snapshot.fiveHour?.utilization, 42)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(UsageParser.parse(Data("not json".utf8)))
        XCTAssertNil(UsageParser.parse(Data("{}".utf8)))
    }
}

final class CodexAdapterTests: XCTestCase {
    func testTurnInfoParsing() throws {
        let payload = Data("""
        {"type":"agent-turn-complete","thread-id":"t1","input-messages":["optimize queries"],"last-assistant-message":"Done, all tests pass."}
        """.utf8)
        let turn = try XCTUnwrap(CodexInterpreter.turnInfo(fromPayload: payload))
        XCTAssertEqual(turn.title, "optimize queries")
        XCTAssertEqual(turn.statusLine, "Done, all tests pass.")
        XCTAssertNil(CodexInterpreter.turnInfo(fromPayload: Data(#"{"type":"other"}"#.utf8)))
    }

    func testNotifyInstallPreservesConfigAndIsIdempotent() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-\(UUID().uuidString).toml").path
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".aisland.bak")
        }
        let seed = """
        model = "o5"
        approval_policy = "on-request"

        [profiles.fast]
        model = "o5-mini"
        """
        try Data(seed.utf8).write(to: URL(fileURLWithPath: path))

        let installer = CodexNotifyInstaller(configPath: path, shimPath: "/fake/island-shim")
        XCTAssertEqual(installer.health(), .missing)
        try installer.install()
        let once = try String(contentsOfFile: path, encoding: .utf8)
        try installer.install()
        let twice = try String(contentsOfFile: path, encoding: .utf8)

        XCTAssertEqual(once, twice, "double install must not duplicate")
        XCTAssertEqual(installer.health(), .installed)
        XCTAssertTrue(once.contains("model = \"o5\""), "user config preserved")
        XCTAssertTrue(once.contains("[profiles.fast]"))
        // notify must be top-level: before the first section header.
        let notifyIndex = try XCTUnwrap(once.range(of: "notify = ")).lowerBound
        let sectionIndex = try XCTUnwrap(once.range(of: "[profiles.fast]")).lowerBound
        XCTAssertLessThan(notifyIndex, sectionIndex)

        try installer.uninstall()
        let final = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(final.contains("island-shim"))
        XCTAssertTrue(final.contains("model = \"o5\""))
    }

    func testConflictingNotifyNotOverwrittenSilently() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-\(UUID().uuidString).toml").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("notify = [\"/usr/bin/other-notifier\"]\n".utf8).write(to: URL(fileURLWithPath: path))
        let installer = CodexNotifyInstaller(configPath: path, shimPath: "/fake/island-shim")
        XCTAssertEqual(installer.health(), .conflicting("notify = [\"/usr/bin/other-notifier\"]"))
        // install() replaces it (backup preserves the original).
        try installer.install()
        XCTAssertEqual(installer.health(), .installed)
    }
}

final class ClaudeHookInstallerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func makeInstaller() -> ClaudeHookInstaller {
        ClaudeHookInstaller(
            settingsPath: directory.appendingPathComponent("settings.json").path,
            shimPath: "/fake/island-shim",
            manifestPath: directory.appendingPathComponent("installed.json").path
        )
    }

    private func settingsJSON(_ installer: ClaudeHookInstaller) throws -> [String: Any] {
        let data = try XCTUnwrap(FileManager.default.contents(atPath: installer.settingsPath))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testInstallIsIdempotent() throws {
        let installer = makeInstaller()
        // Seed with existing user content that must survive.
        let seed = #"{"permissions":{"allow":["Bash(git status:*)"]},"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"say done"}]}]}}"#
        try Data(seed.utf8).write(to: URL(fileURLWithPath: installer.settingsPath))

        try installer.install()
        let once = try settingsJSON(installer)
        try installer.install()
        let twice = try settingsJSON(installer)

        XCTAssertEqual(
            NSDictionary(dictionary: once), NSDictionary(dictionary: twice),
            "double install must not duplicate entries"
        )
        // User's own hook and permissions survive.
        let hooks = try XCTUnwrap(twice["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertTrue(stop.contains { matcher in
            ((matcher["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String) == "say done" }
        })
        XCTAssertNotNil(twice["permissions"])
        // Gate present.
        let pre = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertTrue(pre.contains { matcher in
            ((matcher["hooks"] as? [[String: Any]]) ?? []).contains {
                ($0["command"] as? String)?.contains("island-shim claude-code PreToolUse --gate") == true
            }
        })
        XCTAssertEqual(installer.health(), .stale("/fake/island-shim"))
    }

    func testUninstallRestoresUserHooksOnly() throws {
        let installer = makeInstaller()
        let seed = #"{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"say done"}]}]}}"#
        try Data(seed.utf8).write(to: URL(fileURLWithPath: installer.settingsPath))

        try installer.install()
        try installer.uninstall()
        let final = try settingsJSON(installer)
        let hooks = try XCTUnwrap(final["hooks"] as? [String: Any])
        XCTAssertEqual(hooks.keys.sorted(), ["Stop"])
        XCTAssertEqual(installer.health(), .missing)
    }
}
