import Foundation
import IslandCore
import IslandProtocol

// islandctl — development harness for aisland.
//
// Fakes agent hook traffic by invoking the REAL island-shim from the current
// terminal, so TerminalRef capture, socket transport, and jump behavior are
// exercised exactly as they are for a live agent — with zero API spend.
//
// Commands:
//   islandctl session-start [--id S] [--cwd DIR]
//   islandctl prompt --text "..." [--id S]
//   islandctl permission --tool Bash --arg "rm -rf /tmp/x" [--id S]   (blocks!)
//   islandctl stop [--id S]
//   islandctl session-end [--id S]
//   islandctl demo                      full scripted session
//   islandctl install-hooks [--settings PATH] [--shim PATH]
//   islandctl uninstall-hooks [--settings PATH]
//   islandctl version

func argumentValue(_ flag: String, default fallback: String? = nil) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return fallback }
    return arguments[index + 1]
}

func findShim() -> String? {
    if let env = ProcessInfo.processInfo.environment["ISLAND_SHIM"] { return env }
    let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let sibling = selfPath.deletingLastPathComponent().appendingPathComponent("island-shim").path
    if FileManager.default.fileExists(atPath: sibling) { return sibling }
    let cwdBuild = FileManager.default.currentDirectoryPath + "/.build/debug/island-shim"
    if FileManager.default.fileExists(atPath: cwdBuild) { return cwdBuild }
    return nil
}

@discardableResult
func invokeShim(event: String, gate: Bool, hookJSON: [String: Any]) -> String {
    guard let shim = findShim() else {
        FileHandle.standardError.write(Data("islandctl: island-shim not found (set ISLAND_SHIM)\n".utf8))
        exit(66)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shim)
    process.arguments = ["claude-code", event] + (gate ? ["--gate"] : [])
    let stdin = Pipe(); let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    try? process.run()
    let payload = (try? JSONSerialization.data(withJSONObject: hookJSON)) ?? Data()
    stdin.fileHandleForWriting.write(payload)
    stdin.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

/// Direct NDJSON round trip with the app socket (no shim): send one envelope
/// line, read one response line.
func socketRoundTrip(_ line: Data, timeoutSeconds: Int = 15) -> Data? {
    let socketPath = ProcessInfo.processInfo.environment["ISLAND_SOCKET"]
        ?? ("~/Library/Application Support/aisland/island.sock" as NSString).expandingTildeInPath
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { dest in
        pathBytes.withUnsafeBytes { src in dest.copyBytes(from: src) }
    }
    let connected = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return nil }
    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let sent = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard sent == line.count else { return nil }
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while !response.contains(0x0A) {
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { return nil }
        response.append(contentsOf: buffer[0..<n])
    }
    return response.firstIndex(of: 0x0A).map { response[..<$0] }
}

func baseHookJSON(sessionID: String, cwd: String) -> [String: Any] {
    [
        "session_id": sessionID,
        "cwd": cwd,
        "transcript_path": "\(cwd)/.fake-transcript.jsonl",
    ]
}

let command = CommandLine.arguments.dropFirst().first ?? "version"
let sessionID = argumentValue("--id", default: "fake-\(ProcessInfo.processInfo.processIdentifier)")!
let cwd = argumentValue("--cwd", default: FileManager.default.currentDirectoryPath)!

switch command {
case "version":
    print("islandctl 0.1.0 (wire protocol v\(wireProtocolVersion))")

case "session-start":
    invokeShim(event: "SessionStart", gate: false, hookJSON: baseHookJSON(sessionID: sessionID, cwd: cwd))
    print("session \(sessionID) started")

case "prompt":
    var json = baseHookJSON(sessionID: sessionID, cwd: cwd)
    json["prompt"] = argumentValue("--text", default: "fake prompt")!
    invokeShim(event: "UserPromptSubmit", gate: false, hookJSON: json)
    print("prompt sent")

case "permission":
    var json = baseHookJSON(sessionID: sessionID, cwd: cwd)
    let tool = argumentValue("--tool", default: "Bash")!
    let argument = argumentValue("--arg", default: "rm -rf /tmp/scratch")!
    json["tool_name"] = tool
    switch tool {
    case "Bash": json["tool_input"] = ["command": argument]
    case "Edit", "Write": json["tool_input"] = ["file_path": argument]
    default: json["tool_input"] = ["value": argument]
    }
    print("requesting permission for \(tool)(\(argument)) — waiting for notch decision…")
    let output = invokeShim(event: "PreToolUse", gate: true, hookJSON: json)
    if output.isEmpty {
        print("decision: deferred to agent prompt (ask), or app not running")
    } else {
        print("decision: \(output)")
    }

case "edit-permission":
    var json = baseHookJSON(sessionID: sessionID, cwd: cwd)
    json["tool_name"] = "Edit"
    json["tool_input"] = [
        "file_path": argumentValue("--file", default: "/tmp/project/src/auth/middleware.ts")!,
        "old_string": "const verify = (token) =>\n  jwt.verify(token);",
        "new_string": "const verify = (token) => {\n  if (!token) throw new AuthError('missing');\n  return jwt.verify(token, SECRET);\n}",
    ]
    print("requesting Edit permission — waiting for notch decision…")
    let output = invokeShim(event: "PreToolUse", gate: true, hookJSON: json)
    print(output.isEmpty ? "decision: deferred (ask) or app not running" : "decision: \(output)")

case "plan":
    var json = baseHookJSON(sessionID: sessionID, cwd: cwd)
    json["tool_name"] = "ExitPlanMode"
    json["tool_input"] = [
        "plan": "## Fix auth bug\n\n1. Add missing-token guard in `middleware.ts`\n2. Pass `SECRET` to `jwt.verify`\n3. Add regression test for expired tokens\n\n**Risk**: low — single file.",
    ]
    print("requesting plan review — waiting for notch decision…")
    let output = invokeShim(event: "PreToolUse", gate: true, hookJSON: json)
    print(output.isEmpty ? "decision: deferred (ask) or app not running" : "decision: \(output)")

case "question":
    var json = baseHookJSON(sessionID: sessionID, cwd: cwd)
    json["tool_name"] = "AskUserQuestion"
    json["tool_input"] = [
        "questions": [[
            "question": "Which deployment target?",
            "options": [["label": "Production"], ["label": "Staging"], ["label": "Local only"]],
        ]],
    ]
    let output = invokeShim(event: "PreToolUse", gate: true, hookJSON: json)
    print("question card sent (gate answer: \(output.isEmpty ? "ask/none" : output))")

case "todos":
    var json = baseHookJSON(sessionID: sessionID, cwd: cwd)
    json["tool_name"] = "TodoWrite"
    json["tool_input"] = [
        "todos": [
            ["content": "Fix token validation", "status": "in_progress"],
            ["content": "Add regression test", "status": "pending"],
            ["content": "Verify expired-token behavior", "status": "pending"],
            ["content": "Update integration notes", "status": "pending"],
            ["content": "Reproduce the bug", "status": "completed"],
            ["content": "Trace the middleware flow", "status": "completed"],
            ["content": "Identify the missing guard", "status": "completed"],
            ["content": "Confirm the failing fixture", "status": "completed"],
        ],
    ]
    let output = invokeShim(event: "PreToolUse", gate: true, hookJSON: json)
    print("todos sent (gate answer: \(output.isEmpty ? "ask/none" : output))")

case "stop":
    invokeShim(event: "Stop", gate: false, hookJSON: baseHookJSON(sessionID: sessionID, cwd: cwd))
    print("stop sent")

case "session-end":
    invokeShim(event: "SessionEnd", gate: false, hookJSON: baseHookJSON(sessionID: sessionID, cwd: cwd))
    print("session \(sessionID) ended")

case "demo":
    let base = baseHookJSON(sessionID: sessionID, cwd: cwd)
    invokeShim(event: "SessionStart", gate: false, hookJSON: base)
    var prompt = base; prompt["prompt"] = "fix the auth bug in middleware"
    invokeShim(event: "UserPromptSubmit", gate: false, hookJSON: prompt)
    print("demo session \(sessionID) live — now: islandctl permission --id \(sessionID)")

case "codex-notify":
    // Simulate Codex CLI invoking its notify program: JSON as argv, not stdin.
    guard let shim = findShim() else {
        FileHandle.standardError.write(Data("islandctl: island-shim not found\n".utf8))
        exit(66)
    }
    let notifyJSON = """
    {"type":"agent-turn-complete","thread-id":"\(sessionID)","input-messages":["optimize the database queries"],"last-assistant-message":"Rewrote the slow queries with proper indexes; all tests pass."}
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shim)
    process.arguments = ["codex", "Notify", "--json-arg", notifyJSON]
    try? process.run()
    process.waitUntilExit()
    print("codex turn-complete sent (session \(sessionID))")

case "jump":
    // Jump diagnostics: ask the app to focus THIS terminal pane after a
    // short delay, so you can switch away and watch it come back.
    let delay = Int(argumentValue("--delay", default: "2")!) ?? 2
    let ref = TerminalRef.captureCurrent()
    guard let refJSON = try? String(data: WireCodec.encoder.encode(ref), encoding: .utf8) ?? "" else {
        exit(1)
    }
    print("captured: tty=\(ref.tty ?? "?") term=\(ref.termProgram ?? "?") ancestors=\(ref.ancestorPIDs)")
    print("jumping back here in \(delay)s — switch to another app now…")
    sleep(UInt32(delay))
    let command = CtlCommand(command: "jump", arguments: ["ref": refJSON])
    guard let line = try? WireCodec.encodeLine(Envelope(type: .ctlCommand, body: command)),
          let responseLine = socketRoundTrip(line),
          let response = try? WireCodec.decode(GateResponse.self, from: responseLine)
    else {
        print("no response — is the app running?")
        exit(1)
    }
    print("jump result: \(response.body.reason ?? "unknown")")

case "install-hooks":
    guard let shim = argumentValue("--shim") ?? findShim() else {
        FileHandle.standardError.write(Data("islandctl: pass --shim PATH\n".utf8))
        exit(66)
    }
    let settings = argumentValue("--settings", default: NSHomeDirectory() + "/.claude/settings.json")!
    do {
        try ClaudeHookInstaller(settingsPath: settings, shimPath: shim).install()
        print("hooks installed into \(settings)")
    } catch {
        FileHandle.standardError.write(Data("islandctl: install failed: \(error)\n".utf8))
        exit(1)
    }

case "uninstall-hooks":
    let settings = argumentValue("--settings", default: NSHomeDirectory() + "/.claude/settings.json")!
    do {
        try ClaudeHookInstaller(settingsPath: settings, shimPath: "unused").uninstall()
        print("hooks removed from \(settings)")
    } catch {
        FileHandle.standardError.write(Data("islandctl: uninstall failed: \(error)\n".utf8))
        exit(1)
    }

default:
    FileHandle.standardError.write(Data("islandctl: unknown command '\(command)'\n".utf8))
    exit(64)
}
