import Foundation
import simd

/// A single fallen / airborne autumn leaf.
///
/// Leaves start at a random position near the top of the screen and drift
/// downward under simulated gravity and wind, tumbling as they fall.
/// Once a leaf's `position.y` exceeds `groundY` it transitions to `.resting`
/// and stays there until scattered by a touch.
struct FallenLeaf: Identifiable {

    // MARK: - Identity
    let id: Int

    // MARK: - Visual properties (fixed at spawn)
    let textureIndex: UInt32    // 0–6 — which leaf shape/species from the texture atlas
    let brightness: Float       // subtle per-leaf brightness variation [0.7…1.1]
    let baseScale: Float        // size in points, e.g. 14…28
    let windPhase: Float        // private per-leaf phase offset for wind flutter

    // MARK: - Physics state (updated each frame)
    var position:        SIMD2<Float>
    var velocity:        SIMD2<Float>
    var rotation:        Float          // radians — in-plane orientation
    var angularVelocity: Float          // rad/s — in-plane tumble speed
    var tilt:            Float          // 3-D tilt: 0 = face-on, ±π/2 = edge-on
    var tiltVelocity:    Float          // rad/s — 3-D tumble speed
    var state:           LeafState
    var opacity:         Float          // fades in on spawn, fades out if needed

    // MARK: - Ground anchor (set at spawn, used to detect landing)
    /// Y coordinate (screen-space) at which this leaf is considered grounded.
    let groundY: Float

    /// Seconds until the next gust check. Decremented each frame while resting;
    /// reset on landing and after each gust event. Unused while falling.
    var gustTimer: Float

    // MARK: - GPU helper
    func instanceData() -> LeafInstanceData {
        LeafInstanceData(
            position:     position,
            rotation:     rotation,
            scale:        baseScale,
            brightness:   brightness,
            opacity:      opacity,
            textureIndex: textureIndex,
            tilt:         tilt,
            groundY:      groundY
        )
    }
}

/// The two lifecycle states a leaf can be in.
enum LeafState {
    /// Leaf is falling through the air; velocity and angularVelocity are live.
    case falling
    /// Leaf has settled on the ground; only scattered by touch.
    case resting
}
