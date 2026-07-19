import AppKit

/// The borderless always-on-top panel hosting the island. Nonactivating so
/// clicking it never steals focus from the user's terminal; floats above
/// menu bar and fullscreen apps on every Space.
public final class NotchPanel: NSPanel {
    public init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    // Allow becoming key so future phases can host text input (plan feedback)
    // without activating the owning app.
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}
