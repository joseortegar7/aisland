import SwiftUI
import IslandCore

/// Root SwiftUI content for the island window. The window frame is animated
/// by NotchController; this view renders collapsed pill vs expanded panel.
public struct NotchRootView: View {
    @State private var model: NotchViewModel
    @State private var isShowingSettings = false
    @State private var soundsMuted: Bool
    @AppStorage(PetKind.storageKey) private var petRawValue = PetKind.xwing.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: NotchViewModel) {
        _model = State(initialValue: model)
        _soundsMuted = State(initialValue: model.actions?.soundsMuted ?? false)
    }

    private var islandCornerRadius: CGFloat {
        model.isExpanded ? 28 : 10
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Color.black

            collapsedPill
                .opacity(model.isExpanded ? 0 : 1)
                .scaleEffect(x: model.isExpanded ? 1.04 : 1, y: 1, anchor: .top)
                .allowsHitTesting(!model.isExpanded)

            expandedPanel
                .opacity(model.isExpanded ? 1 : 0)
                .scaleEffect(x: model.isExpanded ? 1 : 0.97, y: model.isExpanded ? 1 : 0.94, anchor: .top)
                .allowsHitTesting(model.isExpanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(IslandShape(bottomCornerRadius: islandCornerRadius))
        .animation(
            reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: model.isExpanded ? 0.34 : 0.24),
            value: model.isExpanded
        )
        .onChange(of: isShowingSettings) { _, presented in
            model.isSettingsPresented = presented
            model.onSettingsPresentationChange?(presented)
        }
        .onChange(of: model.store.sessions.isEmpty) { model.onContentChange?() }
        .onChange(of: model.store.needsAttention) { model.onContentChange?() }
    }

    // MARK: - Collapsed

    /// The pill hugs the physical notch. The center of the pill sits behind
    /// the notch (no real pixels there) so all content lives in the side
    /// wings, which only exist when there is something to show.
    private var collapsedPill: some View {
        HStack {
            if !model.store.sessions.isEmpty || model.store.needsAttention {
                PetView(kind: selectedPet, color: pillColor, isActive: !model.isExpanded)
                    .frame(width: 68, height: 30)
                    .padding(.leading, 8)
                Spacer()
                if sessionCount > 0 {
                    Text("\(sessionCount)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.trailing, 22)
                }
            }
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionCount: Int { model.store.sessions.count }

    private var selectedPet: PetKind {
        PetKind(rawValue: petRawValue) ?? .xwing
    }

    private var pillColor: Color {
        if model.store.firstRequest != nil { return .orange }
        if model.store.firstQuestion != nil { return .purple }
        return model.store.sessions.isEmpty ? .white.opacity(0.3) : .green
    }

    // MARK: - Expanded

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().overlay(Color.white.opacity(0.15))
            if model.store.sessions.isEmpty && model.store.requests.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .padding(.top, model.hasPhysicalNotch ? 26 : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            PetView(kind: selectedPet, color: pillColor, isActive: model.isExpanded)
                .frame(width: 68, height: 30)
            Text("aisland")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
            Spacer()
            if let strip = model.usage?.snapshot?.stripText {
                Text(strip)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.white.opacity(0.08), in: Capsule())
            } else {
                Text("\(sessionCount) session\(sessionCount == 1 ? "" : "s")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Button {
                soundsMuted.toggle()
                model.actions?.setSoundsMuted(soundsMuted)
            } label: {
                Image(systemName: soundsMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(soundsMuted ? .white.opacity(0.4) : .white.opacity(0.7))
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help(soundsMuted ? "Unmute sounds" : "Mute sounds")
            Button {
                isShowingSettings.toggle()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.white.opacity(0.7))
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Settings")
            .popover(isPresented: $isShowingSettings, arrowEdge: .top) {
                IslandSettingsView(actions: model.actions, soundsMuted: $soundsMuted)
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let request = model.store.firstRequest {
                    PermissionCardView(
                        request: request,
                        approve: { model.actions?.approve(request) },
                        deny: { model.actions?.deny(request) },
                        alwaysAllow: { model.actions?.alwaysAllow(request) }
                    )
                }
                if let question = model.store.firstQuestion {
                    QuestionCardView(question: question) { option in
                        model.actions?.answer(question, option: option)
                    }
                }
                ForEach(model.store.ordered) { session in
                    VStack(spacing: 6) {
                        SessionCardView(session: session) {
                            model.actions?.jump(to: session)
                        }
                        if !session.todos.isEmpty {
                            SessionTaskListView(session: session)
                        }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No active sessions")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Text("Start Claude Code in a terminal to see it here")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct IslandSettingsView: View {
    let actions: (any NotchActions)?
    @State private var installed: Set<NotchIntegration>
    @Binding private var soundsMuted: Bool
    @AppStorage(PetKind.storageKey) private var petRawValue = PetKind.xwing.rawValue

    init(actions: (any NotchActions)?, soundsMuted: Binding<Bool>) {
        self.actions = actions
        _installed = State(initialValue: Set(
            NotchIntegration.allCases.filter { actions?.integrationIsInstalled($0) == true }
        ))
        _soundsMuted = soundsMuted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("aisland")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                Spacer()
                Text(version)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(spacing: 10) {
                ForEach(NotchIntegration.allCases, id: \.self) { integration in
                    integrationRow(integration)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Pet")
                    .font(.system(size: 12, weight: .semibold))
                HStack(spacing: 6) {
                    ForEach(PetKind.allCases) { kind in
                        petOption(kind)
                    }
                }
            }

            Divider()

            Toggle(isOn: $soundsMuted) {
                Label("Mute sounds", systemImage: soundsMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            .onChange(of: soundsMuted) { _, muted in actions?.setSoundsMuted(muted) }

            Button {
                actions?.showAgentStatus()
            } label: {
                Label("Agent status", systemImage: "waveform.path.ecg")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Divider()

            Button(role: .destructive) {
                actions?.quitApplication()
            } label: {
                Label("Quit aisland", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 290)
        .preferredColorScheme(.dark)
    }

    private func petOption(_ kind: PetKind) -> some View {
        let isSelected = kind.rawValue == petRawValue
        return Button {
            petRawValue = kind.rawValue
        } label: {
            VStack(spacing: 3) {
                PetView(kind: kind, color: .green, isActive: false)
                    .frame(width: 56, height: 24)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(
                                isSelected ? Color.accentColor : Color.secondary.opacity(0.35),
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
                Text(kind.displayName)
                    .font(.system(size: 8.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Use the \(kind.displayName) pet")
    }

    private func integrationRow(_ integration: NotchIntegration) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(installed.contains(integration) ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(integration.name)
                    .font(.system(size: 12, weight: .semibold))
                Text(integration.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if installed.contains(integration) {
                iconButton("trash", help: "Remove \(integration.name)") {
                    actions?.uninstallIntegration(integration)
                    refresh(integration)
                }
            } else {
                iconButton("plus.circle", help: "Install \(integration.name)") {
                    actions?.installIntegration(integration)
                    refresh(integration)
                }
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func refresh(_ integration: NotchIntegration) {
        if actions?.integrationIsInstalled(integration) == true {
            installed.insert(integration)
        } else {
            installed.remove(integration)
        }
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}

/// Rect flush with the screen's top edge, rounded only at the bottom corners —
/// the classic island silhouette that blends into the physical notch.
struct IslandShape: Shape {
    var bottomCornerRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomCornerRadius }
        set { bottomCornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(max(bottomCornerRadius, 0), rect.width / 2, rect.height / 2)
        let controlOffset = radius * 0.552_284_75

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.maxY - radius + controlOffset),
            control2: CGPoint(x: rect.maxX - radius + controlOffset, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control1: CGPoint(x: rect.minX + radius - controlOffset, y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.maxY - radius + controlOffset)
        )
        path.closeSubpath()
        return path
    }
}
