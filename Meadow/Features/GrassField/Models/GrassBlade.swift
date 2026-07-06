import Foundation
import simd

/// A single grass blade. Root position is fixed at generation time.
/// Only `bendState` changes at runtime.
struct GrassBlade: Identifiable, Sendable {
    let id: UUID

    // MARK: - Fixed geometry (set at generation, never changes)
    let rootPosition: SIMD2<Float>       // Screen-space position (pixels)
    let height: Float                    // Blade height in points (6–24)
    let baseWidth: Float                 // Base width in points (1.5–3.5)
    let baseTilt: Float                  // Resting lean angle in radians (±25°)
    let colourVariant: Float             // 0.0 = darkest, 1.0 = brightest within season palette
    let resistanceCoefficient: Float     // Physics stiffness modifier (0.7–1.3)
    let sizeClass: SizeClass             // short / medium / tall

    // MARK: - Dynamic state (updated each frame)
    var bendState: BendState = .resting

    // MARK: - Types
    enum SizeClass: Sendable {
        case short, medium, tall
    }
}

/// The bend state machine for a single blade.
enum BendState: Sendable {
    case resting
    case touched(angle: Float)
    case holding(angle: Float, remainingDelay: Float)  // seconds
    case recovering(spring: SpringState)
}

/// State for the damped harmonic oscillator used during recovery.
struct SpringState: Sendable {
    var currentAngle: Float
    var velocity: Float
    static let stiffness: Float = 8.0
    static let damping: Float = 0.65
}
