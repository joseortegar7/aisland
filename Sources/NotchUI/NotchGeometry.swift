import AppKit

/// Fallback notch dimensions (points, default scaling) per Apple Silicon
/// MacBook model. The runtime `NSScreen` safe-area/auxiliary APIs are the
/// authority — they return the exact notch rect for every model and scaling
/// mode — so this table is only consulted when those APIs return nothing
/// (e.g. mirrored displays) yet we're still on a notched built-in panel.
public enum MacBookNotchSpec {
    /// Model-identifier prefix → approximate notch size in points.
    static let byModelPrefix: [(prefix: String, size: CGSize)] = [
        // 14" MacBook Pro (M1 Pro/Max 2021 → M4, 1512×982 pt default)
        ("MacBookPro18,3", CGSize(width: 185, height: 32)),
        ("MacBookPro18,4", CGSize(width: 185, height: 32)),
        ("Mac14,5", CGSize(width: 185, height: 32)),
        ("Mac14,9", CGSize(width: 185, height: 32)),
        ("Mac15,3", CGSize(width: 185, height: 32)),
        ("Mac15,6", CGSize(width: 185, height: 32)),
        ("Mac15,8", CGSize(width: 185, height: 32)),
        ("Mac15,10", CGSize(width: 185, height: 32)),
        ("Mac16,1", CGSize(width: 185, height: 32)),
        ("Mac16,6", CGSize(width: 185, height: 32)),
        ("Mac16,8", CGSize(width: 185, height: 32)),
        // 16" MacBook Pro (1728×1117 pt default, taller menu bar)
        ("MacBookPro18,1", CGSize(width: 190, height: 37)),
        ("MacBookPro18,2", CGSize(width: 190, height: 37)),
        ("Mac14,6", CGSize(width: 190, height: 37)),
        ("Mac14,10", CGSize(width: 190, height: 37)),
        ("Mac15,7", CGSize(width: 190, height: 37)),
        ("Mac15,9", CGSize(width: 190, height: 37)),
        ("Mac15,11", CGSize(width: 190, height: 37)),
        ("Mac16,5", CGSize(width: 190, height: 37)),
        ("Mac16,7", CGSize(width: 190, height: 37)),
        // MacBook Air 13.6" (M2/M3, 1470×956 pt default)
        ("Mac14,2", CGSize(width: 180, height: 31)),
        ("Mac15,12", CGSize(width: 180, height: 31)),
        // MacBook Air 15.3" (M2/M3, 1710×1107 pt default)
        ("Mac14,15", CGSize(width: 185, height: 32)),
        ("Mac15,13", CGSize(width: 185, height: 32)),
    ]

    public static func currentModelIdentifier() -> String? {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    public static func fallbackSize(model: String? = currentModelIdentifier()) -> CGSize? {
        guard let model else { return nil }
        return byModelPrefix.first { model.hasPrefix($0.prefix) }?.size
    }
}

/// Where the island lives on a given screen: the physical notch rect on
/// notched MacBooks (exact, per-model, from the runtime APIs), or a
/// synthesized "virtual notch" centered on the menu bar for external or
/// notchless displays.
public struct NotchGeometry: Sendable {
    /// Notch rect in global (bottom-left origin) screen coordinates.
    public let notchRect: CGRect
    public let hasPhysicalNotch: Bool
    public let screenFrame: CGRect

    public init(notchRect: CGRect, hasPhysicalNotch: Bool, screenFrame: CGRect) {
        self.notchRect = notchRect
        self.hasPhysicalNotch = hasPhysicalNotch
        self.screenFrame = screenFrame
    }

    @MainActor
    public static func forScreen(_ screen: NSScreen, virtualNotchWidth: CGFloat = 190) -> NotchGeometry {
        let frame = screen.frame

        // Authoritative: the exact notch for this model at this scaling.
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let height = screen.safeAreaInsets.top
            let rect = CGRect(
                x: left.maxX,
                y: frame.maxY - height,
                width: right.minX - left.maxX,
                height: height
            )
            return NotchGeometry(notchRect: rect, hasPhysicalNotch: true, screenFrame: frame)
        }

        // Built-in panel without safe-area data: per-model fallback table.
        if screen.isBuiltIn, let size = MacBookNotchSpec.fallbackSize() {
            let rect = CGRect(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height,
                width: size.width,
                height: size.height
            )
            return NotchGeometry(notchRect: rect, hasPhysicalNotch: true, screenFrame: frame)
        }

        // External/notchless: virtual notch on the menu bar.
        let menuBarHeight = max(frame.maxY - screen.visibleFrame.maxY, 24)
        let rect = CGRect(
            x: frame.midX - virtualNotchWidth / 2,
            y: frame.maxY - menuBarHeight,
            width: virtualNotchWidth,
            height: menuBarHeight
        )
        return NotchGeometry(notchRect: rect, hasPhysicalNotch: false, screenFrame: frame)
    }

    /// Collapsed island frame: the notch itself, plus `wingWidth` of visible
    /// black on each side for content (0 when idle → pill IS the notch).
    /// Callers can add a `drop` when an intentional extension is needed.
    public func collapsedFrame(wingWidth: CGFloat = 0, drop: CGFloat = 0) -> CGRect {
        CGRect(
            x: notchRect.midX - (notchRect.width + wingWidth * 2) / 2,
            y: notchRect.maxY - (notchRect.height + drop),
            width: notchRect.width + wingWidth * 2,
            height: notchRect.height + drop
        )
    }

    /// Window frame for the expanded panel, top-anchored and centered on the notch.
    public func expandedFrame(size: CGSize) -> CGRect {
        var x = notchRect.midX - size.width / 2
        // Keep the panel on-screen for off-center virtual notches.
        x = min(max(x, screenFrame.minX + 8), screenFrame.maxX - size.width - 8)
        return CGRect(x: x, y: notchRect.maxY - size.height, width: size.width, height: size.height)
    }
}

extension NSScreen {
    var isBuiltIn: Bool {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(number.uint32Value) != 0
    }
}
