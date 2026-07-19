import Foundation
import IslandProtocol

// island-shim <agent> <event> [--gate]
//
// Invoked by agent hooks (e.g. Claude Code's PreToolUse). Reads the hook JSON
// from stdin, forwards it to the aisland app over the local Unix socket,
// and — for gates — blocks until the app answers, then prints the agent's
// decision JSON to stdout.
//
// FAIL-OPEN INVARIANT: if the app is not running, the socket errors, or
// anything at all goes wrong, exit 0 with no output so the agent falls back
// to its own prompt. The shim must never block or break an agent.

let defaultSocketPath = ("~/Library/Application Support/aisland/island.sock" as NSString).expandingTildeInPath

func fail(_ message: @autoclosure () -> String = "") -> Never {
    if ProcessInfo.processInfo.environment["ISLAND_SHIM_DEBUG"] != nil {
        FileHandle.standardError.write(Data("island-shim: \(message())\n".utf8))
    }
    exit(0)
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: island-shim <agent> <event> [--gate] [--json-arg <json>]") }
let agent = args[1]
let eventName = args[2]
let isGate = args.contains("--gate")
let socketPath = ProcessInfo.processInfo.environment["ISLAND_SOCKET"] ?? defaultSocketPath

// Payload source: stdin (Claude Code hooks) or a JSON argv (Codex `notify`
// invokes its program as `notify-program <json>`).
let payload: Data
if let flagIndex = args.firstIndex(of: "--json-arg") {
    if flagIndex + 1 < args.count {
        payload = Data(args[flagIndex + 1].utf8)
    } else {
        payload = Data(args.last?.utf8 ?? "".utf8)
    }
} else {
    payload = FileHandle.standardInput.readDataToEndOfFile()
}
guard payload.count <= wireMaxLineBytes else { fail("payload too large") }

// Pull common identity fields out of the agent's hook JSON. Claude Code
// names first, then Codex notify names as fallbacks.
var sessionID = "unknown"
var cwd = FileManager.default.currentDirectoryPath
var transcriptPath: String?
if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
    sessionID = (object["session_id"] as? String)
        ?? (object["sessionId"] as? String)
        ?? (object["thread-id"] as? String)
        ?? (object["turn-id"] as? String)
        ?? sessionID
    cwd = (object["cwd"] as? String) ?? cwd
    transcriptPath = object["transcript_path"] as? String
}
// Agents that don't identify sessions (e.g. Copilot hooks): key by workspace
// so one card per project instead of one merged card for everything.
if sessionID == "unknown" {
    sessionID = "cwd:" + cwd
}

let event = HookEvent(
    agent: agent,
    event: eventName,
    sessionID: sessionID,
    cwd: cwd,
    transcriptPath: transcriptPath,
    terminal: TerminalRef.captureCurrent(),
    payload: payload,
    host: ProcessInfo.processInfo.environment["ISLAND_REMOTE_HOST"]
)

// --- Plain POSIX Unix-domain socket client (Foundation-only, fast start) ---

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fail("socket() failed") }
defer { close(fd) }
var noSigPipe: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = socketPath.utf8CString
guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { fail("socket path too long") }
withUnsafeMutableBytes(of: &addr.sun_path) { dest in
    pathBytes.withUnsafeBytes { src in
        dest.copyBytes(from: src)
    }
}

let connectResult = withUnsafePointer(to: &addr) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connectResult == 0 else { fail("app not running") }

// Gates can legitimately wait a long time for a human; the agent's own hook
// timeout is the real upper bound. Non-gates get a snappy timeout.
var timeout = timeval(tv_sec: isGate ? 3600 : 2, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

do {
    let envelope = Envelope(type: isGate ? .gateRequest : .hookEvent, body: event)
    let line = try WireCodec.encodeLine(envelope)
    let sent = line.withUnsafeBytes { buffer in
        write(fd, buffer.baseAddress, buffer.count)
    }
    guard sent == line.count else { fail("short write") }
} catch {
    fail("encode failed: \(error)")
}

guard isGate else { exit(0) }

// Block until the app answers with one NDJSON line.
var responseData = Data()
var buffer = [UInt8](repeating: 0, count: 64 * 1024)
while !responseData.contains(0x0A) {
    let n = read(fd, &buffer, buffer.count)
    guard n > 0 else { fail("connection closed before response") }
    responseData.append(contentsOf: buffer[0..<n])
    guard responseData.count <= wireMaxLineBytes else { fail("response too large") }
}

guard let newline = responseData.firstIndex(of: 0x0A),
      let envelope = try? WireCodec.decode(GateResponse.self, from: responseData[..<newline])
else { fail("bad response") }

let response = envelope.body

// "ask" (or any unknown state) = print nothing: the agent shows its own prompt.
guard response.decision == .allow || response.decision == .deny else { exit(0) }

// Format the decision in the agent's native hook-output schema.
switch agent {
case "claude-code":
    let output: [String: Any] = [
        "hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": response.decision.rawValue,
            "permissionDecisionReason": response.reason ?? "Decided from aisland notch",
        ]
    ]
    if let data = try? JSONSerialization.data(withJSONObject: output) {
        FileHandle.standardOutput.write(data)
    }
default:
    // Unknown agents: no gate output support yet; stay silent (fail-open).
    break
}
exit(0)
