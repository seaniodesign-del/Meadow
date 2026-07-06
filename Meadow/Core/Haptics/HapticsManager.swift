import UIKit

/// Minimal haptics wrapper. All feedback is intentionally subtle
/// to preserve the calm, relaxing experience.
///
/// Call `setup(view:)` once after the receiving UIView enters the window
/// hierarchy — UIImpactFeedbackGenerator requires a live view on iOS 17.5+
/// to resolve the correct UIWindowScene; the view-less initialiser silently
/// produces no feedback on modern hardware.
@MainActor
final class HapticsManager {
    static let shared = HapticsManager()

    private var lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private var softGenerator  = UIImpactFeedbackGenerator(style: .soft)

    private var lastPulseTime: CFTimeInterval = 0
    private let pulseInterval: CFTimeInterval = 0.35

    private init() {}

    /// Wire generators to a live view so the Taptic Engine can route feedback
    /// through the correct UIWindowScene.  Call once from viewDidAppear or
    /// equivalent, after the view is in the window hierarchy.
    func setup(view: UIView) {
        lightGenerator = UIImpactFeedbackGenerator(style: .light, view: view)
        softGenerator  = UIImpactFeedbackGenerator(style: .soft,  view: view)
        lightGenerator.prepare()
        softGenerator.prepare()
    }

    /// Call on first touch contact.
    func touchBegan(enabled: Bool) {
        guard enabled else { return }
        lightGenerator.impactOccurred(intensity: 0.5)
    }

    /// Call each frame during active drag. Self-throttles to ~0.35 s between pulses.
    func dragPulse(velocity: CGFloat, enabled: Bool) {
        guard enabled else { return }
        let velocityThreshold: CGFloat = 30
        guard velocity > velocityThreshold else { return }

        let now = CACurrentMediaTime()
        guard now - lastPulseTime >= pulseInterval else { return }
        lastPulseTime = now
        softGenerator.impactOccurred(intensity: 0.3)
    }
}
