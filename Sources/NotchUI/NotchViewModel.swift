import Foundation
import Observation
import IslandCore

/// UI state for one screen's island.
@MainActor
@Observable
public final class NotchViewModel {
    public var isExpanded = false
    public var hasPhysicalNotch = true
    public var isSettingsPresented = false

    /// Live session state; observed by the views.
    public let store: SessionStore

    /// Claude quota tracker; nil or empty snapshot hides the strip.
    public var usage: UsageTracker?

    /// Set by the controller so a separate settings popover can suspend
    /// hover-driven collapse while it owns the pointer.
    @ObservationIgnored
    public var onSettingsPresentationChange: ((Bool) -> Void)?

    /// Set by the controller; called when collapsed-pill content appears or
    /// disappears so the window can re-fit around the notch.
    @ObservationIgnored
    public var onContentChange: (() -> Void)?

    /// Implemented by the app layer (approve/deny/jump).
    @ObservationIgnored
    public weak var actions: (any NotchActions)?

    public init(store: SessionStore) {
        self.store = store
    }
}
