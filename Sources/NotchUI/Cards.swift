import SwiftUI
import IslandCore

public enum NotchIntegration: CaseIterable, Sendable {
    case claudeCode
    case codex
    case copilot

    var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .copilot: "GitHub Copilot"
        }
    }

    var detail: String {
        switch self {
        case .claudeCode: "Lifecycle and approvals"
        case .codex: "Turn notifications"
        case .copilot: "CLI and VS Code hooks"
        }
    }
}

/// Actions the notch UI can trigger; implemented by the app layer.
@MainActor
public protocol NotchActions: AnyObject {
    func approve(_ request: PermissionRequest)
    func deny(_ request: PermissionRequest)
    func alwaysAllow(_ request: PermissionRequest)
    func answer(_ question: QuestionPrompt, option: Int)
    func jump(to session: SessionState)
    func integrationIsInstalled(_ integration: NotchIntegration) -> Bool
    func installIntegration(_ integration: NotchIntegration)
    func uninstallIntegration(_ integration: NotchIntegration)
    var soundsMuted: Bool { get }
    func setSoundsMuted(_ muted: Bool)
    func showAgentStatus()
    func quitApplication()
}

// MARK: - Session card

struct SessionCardView: View {
    let session: SessionState
    let jump: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Button(action: jump) {
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(indicatorColor)
                        .frame(width: 7, height: 7)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(session.title ?? session.projectName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            badge(session.agentDisplayName)
                            if let terminal = session.terminalDisplayName {
                                badge(terminal)
                            }
                            Spacer()
                            Text(elapsed(at: context.date))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        if let status = statusText {
                            Text(status)
                                .font(.system(size: 11))
                                .foregroundStyle(session.phase == .idle ? .green.opacity(0.85) : .white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
    }

    private var statusText: String? {
        if session.phase == .idle { return session.statusLine ?? "Ready" }
        return session.statusLine
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Color.white.opacity(0.12), in: Capsule())
            .foregroundStyle(.white.opacity(0.8))
    }

    private var indicatorColor: Color {
        switch session.phase {
        case .working: .green
        case .awaitingPermission: .orange
        case .idle: .blue
        }
    }

    private func elapsed(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(session.startedAt)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
    }
}

// MARK: - Task list

struct SessionTaskListView: View {
    let session: SessionState

    private var completedCount: Int {
        session.todos.filter { $0.status == .completed }.count
    }

    private var activeCount: Int {
        session.todos.filter { $0.status == .inProgress }.count
    }

    private var pendingCount: Int {
        session.todos.filter { $0.status == .pending }.count
    }

    private var orderedTasks: [TodoItem] {
        session.todos.sorted { left, right in
            rank(left.status) < rank(right.status)
        }
    }

    private var visibleTasks: [TodoItem] {
        Array(orderedTasks.prefix(6))
    }

    private var hiddenTasks: [TodoItem] {
        Array(orderedTasks.dropFirst(visibleTasks.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Text("Tasks")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
                Text("(\(completedCount) done, \(activeCount) in progress, \(pendingCount) open)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))
                Spacer()
                Text(session.projectName)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.28))
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(visibleTasks.enumerated()), id: \.offset) { _, task in
                    taskRow(task)
                }
            }

            if !hiddenTasks.isEmpty {
                Text(hiddenSummary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.34))
                    .padding(.leading, 22)
            }
        }
        .padding(11)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.055), lineWidth: 1)
        }
    }

    private func taskRow(_ task: TodoItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            taskIcon(task.status)
                .frame(width: 14, height: 14)
            Text(task.content)
                .font(.system(size: 11, weight: task.status == .inProgress ? .semibold : .regular))
                .foregroundStyle(taskColor(task.status))
                .strikethrough(task.status == .completed, color: .white.opacity(0.28))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func taskIcon(_ status: TodoItem.Status) -> some View {
        switch status {
        case .pending:
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.white.opacity(0.32), lineWidth: 1.2)
                .frame(width: 12, height: 12)
        case .inProgress:
            Image(systemName: "circle.dotted")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
        case .completed:
            Image(systemName: "checkmark.square.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
        }
    }

    private func taskColor(_ status: TodoItem.Status) -> Color {
        switch status {
        case .pending: .white.opacity(0.68)
        case .inProgress: .white.opacity(0.9)
        case .completed: .white.opacity(0.3)
        }
    }

    private var hiddenSummary: String {
        let hiddenCompleted = hiddenTasks.filter { $0.status == .completed }.count
        if hiddenCompleted == hiddenTasks.count {
            return "… +\(hiddenCompleted) completed"
        }
        return "… +\(hiddenTasks.count) more"
    }

    private func rank(_ status: TodoItem.Status) -> Int {
        switch status {
        case .inProgress: 0
        case .pending: 1
        case .completed: 2
        }
    }
}

// MARK: - Permission / plan review card

struct PermissionCardView: View {
    let request: PermissionRequest
    let approve: () -> Void
    let deny: () -> Void
    let alwaysAllow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            detailView
            buttons
        }
        .padding(10)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.35), lineWidth: 1))
    }

    private var accent: Color { request.isPlanReview ? .cyan : .orange }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: request.isPlanReview ? "doc.text.magnifyingglass" : "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(accent)
            Text(request.isPlanReview ? "Plan Review" : "Permission Request")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accent)
            Spacer()
            Text(request.toolName)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(accent.opacity(0.2), in: Capsule())
                .foregroundStyle(accent)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch request.details {
        case .bash(let command):
            codeBlock(command)
        case .fileEdit(let path, let old, let new):
            VStack(alignment: .leading, spacing: 4) {
                filePathLabel(path)
                DiffView(old: old, new: new)
            }
        case .fileWrite(let path, let content):
            VStack(alignment: .leading, spacing: 4) {
                filePathLabel(path)
                DiffView(old: "", new: String(content.prefix(1200)))
            }
        case .plan(let markdown):
            ScrollView {
                Text(renderedMarkdown(markdown))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
            .padding(8)
            .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .generic(let json):
            codeBlock(json.isEmpty ? request.summary : json)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            actionButton("Deny ⌘N", background: .white.opacity(0.1), foreground: .white.opacity(0.85), action: deny)
                .keyboardShortcut("n", modifiers: .command)
            if !request.isPlanReview && request.canAlwaysAllow {
                actionButton("Always ⌘A", background: .white.opacity(0.1), foreground: accent, action: alwaysAllow)
                    .keyboardShortcut("a", modifiers: .command)
            }
            actionButton(request.isPlanReview ? "Approve ⌘Y" : "Allow ⌘Y", background: .white, foreground: .black, action: approve)
                .keyboardShortcut("y", modifiers: .command)
        }
    }

    private func actionButton(_ title: String, background: Color, foreground: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(background, in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(foreground)
        }
        .buttonStyle(.plain)
    }

    private func filePathLabel(_ path: String) -> some View {
        Text(path)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .truncationMode(.head)
    }

    private func codeBlock(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 100)
        .padding(8)
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func renderedMarkdown(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }
}

/// Naive removed/added line view — matches the marketing-site look
/// (red − lines, green + lines) without a real LCS diff.
struct DiffView: View {
    let old: String
    let new: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 6) {
                        Text(line.marker)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(line.color)
                            .frame(width: 10)
                        Text(line.text)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(line.color)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(line.color.opacity(0.08))
                }
            }
        }
        .frame(maxHeight: 140)
        .padding(6)
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private struct Line {
        let marker: String
        let text: String
        let color: Color
    }

    private var lines: [Line] {
        let removed = old.isEmpty ? [] : old.components(separatedBy: "\n").prefix(20)
        let added = new.isEmpty ? [] : new.components(separatedBy: "\n").prefix(20)
        return removed.map { Line(marker: "−", text: $0, color: .red.opacity(0.9)) }
            + added.map { Line(marker: "+", text: $0, color: .green.opacity(0.9)) }
    }
}

// MARK: - Question card

struct QuestionCardView: View {
    let question: QuestionPrompt
    let answer: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.purple)
                Text("Claude asks")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.purple)
                Spacer()
            }
            Text(question.question)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 5) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    optionButton(index: index, label: option)
                }
            }
        }
        .padding(10)
        .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.35), lineWidth: 1))
    }

    @ViewBuilder
    private func optionButton(index: Int, label: String) -> some View {
        let button = Button {
            answer(index + 1)
        } label: {
            HStack {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.purple)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)

        switch index {
        case 0: button.keyboardShortcut("1", modifiers: .command)
        case 1: button.keyboardShortcut("2", modifiers: .command)
        case 2: button.keyboardShortcut("3", modifiers: .command)
        case 3: button.keyboardShortcut("4", modifiers: .command)
        default: button
        }
    }
}
