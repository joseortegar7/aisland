import Foundation
import Observation

/// One rate-limit window (Claude's 5-hour and 7-day quotas).
public struct UsageWindow: Sendable, Equatable {
    /// 0–100.
    public let utilization: Int
    public let resetsAt: Date?

    public init(utilization: Int, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    /// "11% · 3h59m" — the compact strip segment.
    public func compactText(now: Date = Date()) -> String {
        var text = "\(utilization)%"
        if let resetsAt, resetsAt > now {
            let seconds = Int(resetsAt.timeIntervalSince(now))
            let days = seconds / 86400
            let hours = (seconds % 86400) / 3600
            let minutes = (seconds % 3600) / 60
            let countdown: String
            if days > 0 {
                countdown = "\(days)d\(hours)h"
            } else if hours > 0 {
                countdown = "\(hours)h\(minutes)m"
            } else {
                countdown = "\(minutes)m"
            }
            text += " · \(countdown)"
        }
        return text
    }
}

public struct UsageSnapshot: Sendable, Equatable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    public let fetchedAt: Date

    public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, fetchedAt: Date = Date()) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.fetchedAt = fetchedAt
    }

    /// "5h 11% · 3h59m  |  7d 2% · 6d1h"
    public var stripText: String? {
        var parts: [String] = []
        if let fiveHour { parts.append("5h " + fiveHour.compactText()) }
        if let sevenDay { parts.append("7d " + sevenDay.compactText()) }
        return parts.isEmpty ? nil : parts.joined(separator: "  |  ")
    }
}

public enum UsageParser {
    /// Tolerant parse of the OAuth usage endpoint response. Handles
    /// utilization as 0–100 or 0–1, and snake_case window keys.
    public static func parse(_ data: Data) -> UsageSnapshot? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let fiveHour = window(object["five_hour"]) ?? window(object["fiveHour"])
        let sevenDay = window(object["seven_day"]) ?? window(object["sevenDay"])
        if fiveHour == nil && sevenDay == nil { return nil }
        return UsageSnapshot(fiveHour: fiveHour, sevenDay: sevenDay)
    }

    private static func window(_ value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any] else { return nil }
        let rawUtilization = (dict["utilization"] as? Double)
            ?? (dict["utilization"] as? Int).map(Double.init)
        guard var utilization = rawUtilization else { return nil }
        if utilization <= 1.0 { utilization *= 100 }
        var resetsAt: Date?
        if let iso = (dict["resets_at"] as? String) ?? (dict["resetsAt"] as? String) {
            let formatter = ISO8601DateFormatter()
            resetsAt = formatter.date(from: iso)
            if resetsAt == nil {
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                resetsAt = formatter.date(from: iso)
            }
        }
        return UsageWindow(utilization: Int(utilization.rounded()), resetsAt: resetsAt)
    }
}

/// Fetches Claude quota utilization on a timer, using the same OAuth token
/// Claude Code itself stores (Keychain first, credentials file fallback).
/// Everything is local + read-only; if no token is reachable the strip hides.
@MainActor
@Observable
public final class UsageTracker {
    public private(set) var snapshot: UsageSnapshot?

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let refreshInterval: Duration

    public init(refreshInterval: Duration = .seconds(120)) {
        self.refreshInterval = refreshInterval
    }

    public func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.refreshInterval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    public func refresh() async {
        guard let token = await Self.loadAccessToken() else {
            snapshot = nil
            NSLog("aisland usage: no OAuth token reachable; hiding quota strip")
            return
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                snapshot = nil
                NSLog("aisland usage: endpoint returned %d", (response as? HTTPURLResponse)?.statusCode ?? -1)
                return
            }
            guard let parsed = UsageParser.parse(data) else {
                snapshot = nil
                NSLog("aisland usage: endpoint returned an invalid response")
                return
            }
            snapshot = parsed
            NSLog("aisland usage: %@", parsed.stripText ?? "n/a")
        } catch {
            snapshot = nil
            NSLog("aisland usage: fetch failed: \(error.localizedDescription)")
        }
    }

    /// Claude Code stores its OAuth credentials in the login Keychain
    /// ("Claude Code-credentials"); older/Linux-style installs use
    /// ~/.claude/.credentials.json. First Keychain read may show a one-time
    /// permission dialog — "Always Allow" persists it.
    nonisolated static func loadAccessToken() async -> String? {
        let json: Data? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let filePath = NSHomeDirectory() + "/.claude/.credentials.json"
                if let data = FileManager.default.contents(atPath: filePath) {
                    continuation.resume(returning: data)
                    return
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                // Never hang the app on a Keychain dialog nobody answers.
                let deadline = DispatchTime.now() + .seconds(8)
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    if process.isRunning { process.terminate() }
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: output)
            }
        }
        guard let json,
              let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
        else { return nil }
        let oauth = (object["claudeAiOauth"] as? [String: Any]) ?? object
        return oauth["accessToken"] as? String
    }
}
