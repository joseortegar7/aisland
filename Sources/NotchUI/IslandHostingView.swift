import AppKit
import SwiftUI

/// Hosts the island SwiftUI content inside a plain (non-flipped) AppKit view
/// and masks the actual WindowServer surface to the island silhouette.
@MainActor
final class IslandContainerView<Content: View>: NSView {
    var collapsedHeight: CGFloat {
        didSet { needsLayout = true }
    }
    var expandedHeight: CGFloat {
        didSet { needsLayout = true }
    }

    private static var collapsedRadius: CGFloat { 10 }
    private static var expandedRadius: CGFloat { 26 }
    private static var collapsedTopRadius: CGFloat { 10 }
    private static var expandedTopRadius: CGFloat { 16 }

    let hostingView: NSHostingView<Content>
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    private let shapeMask = CAShapeLayer()

    init(rootView: Content, collapsedHeight: CGFloat, expandedHeight: CGFloat) {
        self.collapsedHeight = collapsedHeight
        self.expandedHeight = expandedHeight
        self.hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.mask = shapeMask

        // The controller owns the frame; never let SwiftUI intrinsic sizing
        // resize the borderless panel.
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Non-flipped so `MinY` corners map to the visual bottom.
    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
        guard !bounds.isEmpty else { return }
        let heightRange = max(expandedHeight - collapsedHeight, 1)
        let progress = min(max((bounds.height - collapsedHeight) / heightRange, 0), 1)
        let radius = Self.collapsedRadius + (Self.expandedRadius - Self.collapsedRadius) * progress
        let topRadius = Self.collapsedTopRadius + (Self.expandedTopRadius - Self.collapsedTopRadius) * progress
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeMask.frame = bounds
        shapeMask.contentsScale = window?.backingScaleFactor ?? 2
        shapeMask.path = islandPath(
            in: bounds,
            topRadius: topRadius,
            bottomRadius: radius
        )
        shapeMask.fillColor = NSColor.black.cgColor
        CATransaction.commit()
    }

    /// The classic notch-blending island: a full-width body whose top edge is
    /// flush with the screen, joined to the menu bar by small concave (inverse)
    /// fillets at the two top-outer corners, and rounded at the bottom corners.
    /// `maxY` is the visual top (the view is non-flipped).
    private func islandPath(
        in rect: CGRect,
        topRadius: CGFloat,
        bottomRadius: CGFloat
    ) -> CGPath {
        let tr = min(topRadius, rect.width / 2, rect.height / 2)
        let br = min(bottomRadius, rect.width / 2, rect.height / 2)
        let k: CGFloat = 0.552_284_75
        let path = CGMutablePath()

        // Vibe Island silhouette: the top edge is flush and spans the full
        // width; at each top-outer corner a small concave "foot" flares out
        // into the menu bar. The vertical walls are inset by `tr`, and the
        // bottom corners are ordinary rounded corners.
        path.move(to: CGPoint(x: rect.maxX - tr, y: rect.minY + br))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.maxY - tr))
        // Concave top-right foot up to the full-width top edge.
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX - tr, y: rect.maxY - tr + k * tr),
            control2: CGPoint(x: rect.maxX - k * tr, y: rect.maxY)
        )
        // Full-width top edge.
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        // Concave top-left foot down to the left wall.
        path.addCurve(
            to: CGPoint(x: rect.minX + tr, y: rect.maxY - tr),
            control1: CGPoint(x: rect.minX + k * tr, y: rect.maxY),
            control2: CGPoint(x: rect.minX + tr, y: rect.maxY - tr + k * tr)
        )
        // Left wall down to the rounded bottom-left corner.
        path.addLine(to: CGPoint(x: rect.minX + tr, y: rect.minY + br))
        path.addCurve(
            to: CGPoint(x: rect.minX + tr + br, y: rect.minY),
            control1: CGPoint(x: rect.minX + tr, y: rect.minY + br - k * br),
            control2: CGPoint(x: rect.minX + tr + br - k * br, y: rect.minY)
        )
        // Bottom edge.
        path.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX - tr, y: rect.minY + br),
            control1: CGPoint(x: rect.maxX - tr - br + k * br, y: rect.minY),
            control2: CGPoint(x: rect.maxX - tr, y: rect.minY + br - k * br)
        )
        path.closeSubpath()
        return path
    }
}