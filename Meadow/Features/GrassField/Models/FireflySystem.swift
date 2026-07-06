import SwiftUI

/// Models a single firefly's position and bioluminescent flash state.
///
/// Real fireflies (Photinus pyralis) produce a characteristic flash pattern:
/// a ~0.3 s flash followed by a 5–7 s dark interval, repeated continuously.
/// This model simulates that rhythm per-instance with slight random variation
/// so the 10 fireflies never pulse in unison.
struct Firefly: Identifiable {
    let id: Int

    /// Normalised position in the view (0…1 in both axes).
    /// x: 0 = left edge, 1 = right edge
    /// y: 0 = top edge, 1 = bottom edge
    let normalised: CGPoint

    /// Phase offset (seconds) — seeds each firefly into a unique position
    /// in its flash cycle so they don't all glow at the same time.
    let phaseOffset: Double

    /// Dark-interval duration in seconds (varies 5–7 s for realism).
    let darkPeriod: Double

    /// Whether this firefly floats higher (above grass) or stays low.
    let isFlying: Bool
}

/// Manages the collection of fireflies and computes per-firefly brightness
/// for a given elapsed time and time-of-day value.
///
/// All state is value-type and deterministic — pass `elapsedSeconds` from
/// a `TimelineView` and read `brightness(for:at:)` in the drawing code.
struct FireflySystem {

    // MARK: - Constants

    /// Hour after which fireflies begin to appear (8:30 PM).
    static let appearHour: Double = 20.5
    /// Hour at which fireflies are fully visible (8:45 PM).
    static let fullBrightHour: Double = 20.75

    /// Flash duration in seconds (the bright ON phase).
    private static let flashDuration: Double = 0.28
    /// Peak brightness multiplier for the glow.
    static let peakBrightness: Double = 1.0

    // MARK: - Fireflies

    let fireflies: [Firefly]

    /// Build a deterministic set of 10 fireflies from a fixed seed.
    init() {
        var rng = SeededRNG(seed: 0xF1F1F1F1)

        fireflies = (0..<10).map { index in
            // Positions: mix of low (in the grass) and higher (flying).
            // Low fireflies cluster in the bottom 40%; flyers spread 20–70%.
            let isFlying = index >= 6   // 6 low, 4 flying
            let yRange: ClosedRange<Double> = isFlying ? 0.18...0.65 : 0.58...0.88
            let x = rng.nextDouble(in: 0.04...0.96)
            let y = rng.nextDouble(in: yRange)

            // Each flash cycle = darkPeriod + flashDuration.
            // Phase offset scatters fireflies across their own cycles.
            let darkPeriod = rng.nextDouble(in: 10.0...16.0)
            let cycleLen   = darkPeriod + FireflySystem.flashDuration
            let phase      = rng.nextDouble(in: 0...cycleLen)

            return Firefly(
                id:          index,
                normalised:  CGPoint(x: x, y: y),
                phaseOffset: phase,
                darkPeriod:  darkPeriod,
                isFlying:    isFlying
            )
        }
    }

    // MARK: - Brightness

    /// Returns the brightness [0, 1] for a single firefly at `elapsed` seconds,
    /// scaled by the global night-visibility factor derived from `timeOfDay`.
    func brightness(for firefly: Firefly, elapsed: Double, timeOfDay: Double) -> Double {
        // Global fade-in gate: 0 before 8:30 PM, 1 at 8:45 PM.
        let nightFactor: Double
        if timeOfDay < FireflySystem.appearHour {
            nightFactor = 0
        } else if timeOfDay > FireflySystem.fullBrightHour {
            nightFactor = 1
        } else {
            let raw = (timeOfDay - FireflySystem.appearHour)
                    / (FireflySystem.fullBrightHour - FireflySystem.appearHour)
            // Smooth step
            nightFactor = raw * raw * (3 - 2 * raw)
        }
        guard nightFactor > 0 else { return 0 }

        // Per-firefly flash cycle
        let cycleLen  = firefly.darkPeriod + FireflySystem.flashDuration
        let phase     = (elapsed + firefly.phaseOffset).truncatingRemainder(dividingBy: cycleLen)
        // The flash occupies the last `flashDuration` seconds of the cycle.
        let flashStart = firefly.darkPeriod
        guard phase >= flashStart else { return 0 }

        let flashProgress = (phase - flashStart) / FireflySystem.flashDuration
        // Bell-shaped envelope: ramp up quickly, ramp down more slowly.
        // pow(sin(π·t), 0.6) gives a fast rise and gentle tail.
        let envelope = pow(sin(.pi * flashProgress), 0.6)

        return envelope * nightFactor * FireflySystem.peakBrightness
    }
}

// MARK: - Seeded RNG

/// Simple xorshift64 PRNG for reproducible firefly placement.
private struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 1 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        let raw = Double(next()) / Double(UInt64.max)
        return range.lowerBound + raw * (range.upperBound - range.lowerBound)
    }
}
