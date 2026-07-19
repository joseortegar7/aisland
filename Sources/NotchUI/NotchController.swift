import AppKit
import SwiftUI
import IslandCore

/// Owns the island window for one screen: builds the panel, computes frames
/// from NotchGeometry, and animates collapse/expand on hover.
@MainActor
public final class NotchController {
    public let screen: NSScreen
    public let model: NotchViewModel

    private let panel: NotchPanel
    private let container: IslandContainerView<NotchRootView>
    private var geometry: NotchGeometry
    private var collapseTask: Task<Void, Never>?

    public var expandedSize = CGSize(width: 620, height: 280)

    /// Collapsed chrome: idle = the bare notch (invisible blend); with
    /// sessions = wings for the sprite and count badge, Vibe Island style.
    private var collapsedWing: CGFloat {
        model.store.sessions.isEmpty && !model.store.needsAttention ? 0 : 82
    }

    public init(screen: NSScreen, model: NotchViewModel) {
        self.screen = screen
        self.model = model
        self.geometry = NotchGeometry.forScreen(screen)
        self.model.hasPhysicalNotch = geometry.hasPhysicalNotch

        panel = NotchPanel(contentRect: geometry.collapsedFrame())
        container = IslandContainerView(
            rootView: NotchRootView(model: model),
            collapsedHeight: geometry.notchRect.height,
            expandedHeight: expandedSize.height
        )
        container.autoresizingMask = [.width, .height]
        container.frame = panel.contentLayoutRect
        panel.contentView = container

        container.onHoverChange = { [weak self] hovering in
            self?.hoverChanged(hovering)
        }
        model.onSettingsPresentationChange = { [weak self] presented in
            guard let self else { return }
            if presented {
                self.collapseTask?.cancel()
                self.setExpanded(true)
            } else {
                self.hoverChanged(self.pointerIsInsidePanel)
            }
        }
        model.onContentChange = { [weak self] in
            self?.refreshCollapsedFrame()
        }

        panel.setFrame(geometry.collapsedFrame(wingWidth: collapsedWing), display: true)
        panel.orderFrontRegardless()

        NSLog(
            "aisland geometry: screen=%@ safeTop=%.1f auxL=%@ auxR=%@ notch=%@ target=%@ actual=%@",
            NSStringFromRect(screen.frame),
            screen.safeAreaInsets.top,
            String(describing: screen.auxiliaryTopLeftArea),
            String(describing: screen.auxiliaryTopRightArea),
            NSStringFromRect(geometry.notchRect),
            NSStringFromRect(geometry.collapsedFrame(wingWidth: collapsedWing)),
            NSStringFromRect(panel.frame)
        )
    }

    public func refreshGeometry() {
        geometry = NotchGeometry.forScreen(screen)
        model.hasPhysicalNotch = geometry.hasPhysicalNotch
        container.collapsedHeight = geometry.notchRect.height
        container.expandedHeight = expandedSize.height
        applyFrame(animated: false)
    }

    /// Re-fit the collapsed pill when content appears/disappears.
    public func refreshCollapsedFrame() {
        guard !model.isExpanded else { return }
        applyFrame(animated: true)
    }

    public func setExpanded(_ expanded: Bool, takeFocus: Bool = true) {
        if model.isExpanded != expanded {
            model.isExpanded = expanded
            applyFrame(animated: true)
        }
        if expanded && takeFocus {
            // Let approval buttons receive ⌘Y/⌘N without activating the app.
            panel.makeKey()
        }
    }

    public func close() {
        collapseTask?.cancel()
        panel.orderOut(nil)
    }

    private func hoverChanged(_ hovering: Bool) {
        collapseTask?.cancel()
        if hovering {
            setExpanded(true)
        } else {
            // Never auto-collapse while an approval or question is waiting.
            guard !model.store.needsAttention, !model.isSettingsPresented else { return }
            // Window resizing can make AppKit regenerate tracking areas and
            // emit a synthetic exit. Ignore it unless the pointer is actually
            // outside the panel in global screen coordinates.
            guard !pointerIsInsidePanel else { return }
            // Grace period so brief exits (e.g. crossing the notch) don't flap.
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                guard let self,
                      !self.model.store.needsAttention,
                      !self.model.isSettingsPresented,
                      !self.pointerIsInsidePanel
                else { return }
                self.setExpanded(false)
            }
        }
    }

    private var pointerIsInsidePanel: Bool {
        panel.frame.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation)
    }

    private func applyFrame(animated: Bool) {
        let target = model.isExpanded
            ? geometry.expandedFrame(size: expandedSize)
            : geometry.collapsedFrame(wingWidth: collapsedWing)
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = model.isExpanded ? 0.34 : 0.24
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.16,
                    1,
                    0.3,
                    1
                )
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }
}
