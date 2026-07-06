import SwiftUI

/// Rotary season-selection dial — 629 pt circle with liquid-glass surface.
///
/// Four season icons sit at 90° intervals on the rim; eight fading tick marks
/// flank each icon. The whole disc rotates with a horizontal drag gesture and
/// snaps to the nearest season on release.
///
/// Only the top ≈ 270 pt is visible above the screen edge; the rest extends below.
struct SeasonDialView: View {

    /// Season currently at the 12-o'clock position.
    @Binding var selectedSeason: Season

    /// Called immediately after each spring-snap completes.
    var onSnapped: () -> Void = {}

    /// Live angular drift from the nearest snap position (degrees).
    /// 0 when snapped; grows during drag. Used by the parent to blur the season name.
    @Binding var drift: Double

    // MARK: - Geometry (matches Figma 629 × 629 frame)

    static let diameter: CGFloat = 629
    private var radius:      CGFloat { Self.diameter / 2 }
    // Lowered by 24 pt from 283 → 259 per design. Icons share the same radius
    // so each SF Symbol sits on the same arc as the tick capsules around it.
    private let tickRadius:  CGFloat = 259
    private let iconRadius:  CGFloat = 259

    // MARK: - Season order (clockwise from 12-o'clock)
    //
    // Index 0 = top at rotation 0. To bring index `i` to top, rotate by -(i × 90)°.

    private let seasons: [Season] = [.fall, .winter, .spring, .summer]

    // MARK: - Tick marks
    //
    // Eight offsets per icon at ±10°, ±20°, ±30°, ±40°. Combined with the icons
    // at multiples of 90°, this yields a uniform 10° spacing across the entire
    // ring — every gap (icon→tick→tick→…→tick→icon) is exactly 10°.
    //
    // All ticks share the same size and base colour; their on-screen brightness
    // is computed at render time by `worldBrightness(localAngle:)` so the
    // highlight halo stays fixed at 12 o'clock as the dial rotates underneath.

    private let tickOffsets: [Double] = [-40, -30, -20, -10, 10, 20, 30, 40]

    // MARK: - Rotation state

    @State private var baseAngle:  Double = 0   // committed snap angle (degrees)
    @State private var dragDelta:  Double = 0   // live drag offset (degrees)

    /// Index of the nearest 90° step. Increments every time the dial crosses a
    /// boundary mid-drag — fires a `.selection` haptic via `sensoryFeedback`.
    @State private var stepIndex: Int = 0

    private var currentAngle: Double { baseAngle + dragDelta }

    /// Nearest multiple of 90° to the current angle.
    private var snapAngle: Double { (currentAngle / 90).rounded() * 90 }

    // MARK: - Body

    var body: some View {
        ZStack {
            // ── Liquid-glass background (iOS 26) ─────────────────────────────
            // Dark tinted glass: keeps the refraction edge / specular highlight
            // but darkens the underlying grass for contrast — no milky white frost.
            Circle()
                .glassEffect(.clear.tint(.black.opacity(0.35)))

            // ── Rotating content ──────────────────────────────────────────────
            // Each element's brightness is driven by `worldBrightness`, which
            // uses the element's world-space angle (local + currentAngle). The
            // highlight halo therefore stays anchored at 12 o'clock while icons
            // and ticks rotate THROUGH it — passing into the bright zone as the
            // dial spins.
            ZStack {
                // Season icons at the rim
                ForEach(Array(seasons.enumerated()), id: \.offset) { idx, season in
                    let dialAngle = Double(idx) * 90.0
                    Image(systemName: season.sfSymbol)
                        .font(.system(size: 26, weight: .semibold))
                        .symbolVariant(.fill)
                        .foregroundStyle(.white)
                        .opacity(worldBrightness(localAngle: dialAngle))
                        .offset(y: -iconRadius)
                        .rotationEffect(.degrees(dialAngle))
                }

                // Tick marks — 8 per icon × 4 icons = 32 total, all uniform size.
                ForEach(0..<seasons.count, id: \.self) { idx in
                    ForEach(tickOffsets.indices, id: \.self) { ti in
                        let dialAngle = Double(idx) * 90.0 + tickOffsets[ti]
                        Capsule()
                            .fill(.white)
                            .frame(width: 4, height: 19)
                            .opacity(worldBrightness(localAngle: dialAngle))
                            .offset(y: -tickRadius)
                            .rotationEffect(.degrees(dialAngle))
                    }
                }
            }
            .rotationEffect(.degrees(currentAngle))
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .contentShape(Circle())
        .gesture(dragGesture)
        // Stepped tactile feedback: subtle "tick" each time the dial crosses
        // a 90° boundary mid-drag. `.selection` mirrors UIKit's
        // UISelectionFeedbackGenerator — the right semantic for a picker wheel.
        .sensoryFeedback(.selection, trigger: stepIndex)
        .onAppear { setInitialAngle() }
    }

    // MARK: - Drag gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                // 0.25 °/pt gives natural feel for a 629 pt dial
                dragDelta = value.translation.width * 0.25
                drift = abs(currentAngle - snapAngle)

                // ── Stepped haptic ─────────────────────────────────────────────
                // Fire a `.selection` tick each time the dial passes a 90° boundary.
                // We round to the nearest step; the trigger only fires when the
                // rounded value actually changes from the previous frame.
                let newStep = Int((currentAngle / 90).rounded())
                if newStep != stepIndex {
                    stepIndex = newStep
                }
            }
            .onEnded { _ in
                let target = snapAngle
                withAnimation(.spring(response: 0.36, dampingFraction: 0.68)) {
                    baseAngle = target
                    dragDelta = 0
                }
                drift = 0
                commitSeason(from: target)
            }
    }

    // MARK: - Helpers

    /// Set initial rotation so the preselected season starts at 12 o'clock.
    private func setInitialAngle() {
        guard let idx = seasons.firstIndex(of: selectedSeason) else { return }
        baseAngle = -Double(idx) * 90
    }

    /// Map a snapped angle back to the Season that is now at 12 o'clock.
    private func commitSeason(from angle: Double) {
        let raw    = Int((-angle / 90).rounded())
        let idx    = ((raw % seasons.count) + seasons.count) % seasons.count
        let season = seasons[idx]
        if season != selectedSeason {
            selectedSeason = season
            onSnapped()
        }
    }

    /// Brightness (opacity, applied to a fully-white fill) for any dial element
    /// based on its world-space angular distance from 12 o'clock.
    ///
    /// - Parameter localAngle: the element's angle within the unrotated dial
    ///   (degrees clockwise from the dial's local top).
    /// - Returns: an opacity in `[0.30, 1.00]`. `1.00` at 0°, smoothstep-easing
    ///   down to `0.30` once the element is ≥ 50° away from 12 o'clock.
    ///
    /// Because every element is fed through the same function each render,
    /// the bright "halo" stays pinned to the top of the screen while icons and
    /// ticks slide through it — producing the rotating illumination effect.
    private func worldBrightness(localAngle: Double) -> Double {
        var a = (localAngle + currentAngle).truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        let diff = a > 180 ? 360 - a : a   // [0, 180]

        // Smoothstep over the 50° halo, then flatline at the dim floor.
        let t      = max(0, min(1, diff / 50))
        let smooth = t * t * (3 - 2 * t)
        return 1.0 - smooth * 0.70   // 1.00 → 0.30
    }
}

// MARK: - Preview

#Preview("Season Dial") {
    @Previewable @State var season: Season = .fall
    @Previewable @State var drift: Double = 0
    ZStack {
        Color.black.ignoresSafeArea()
        SeasonDialView(selectedSeason: $season, drift: $drift)
    }
}
