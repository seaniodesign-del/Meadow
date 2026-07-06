import Foundation
import simd

/// Manages the 12 dandelions that appear during spring season.
///
/// Each dandelion has a fixed root position in the grass field, a stem that
/// bends with the same wind system as grass, and a fluffy puff head.
/// Touch interaction bends nearby stems; they spring back over time.
@MainActor
final class DandelionSystem {

    // MARK: - Constants
    static let count: Int    = 12
    private static let touchRadius: Float    = 80.0
    private static let maxTouchBend: Float   = 0.35   // radians at contact centre
    private static let springBackRate: Float = 3.0    // 1/s — how fast bend decays

    // MARK: - Public
    private(set) var instanceData: [DandelionInstanceData] = []

    // MARK: - Private
    private var dandelions: [DandelionBlade] = []
    private var rng: DandelionRNG

    // MARK: - Init

    init(screenSize: CGSize) {
        rng = DandelionRNG(seed: 0xDA4D3_110C)
        dandelions.reserveCapacity(Self.count)
        spawnAll(screenSize: screenSize)
        rebuildInstanceData()
    }

    // MARK: - Spawn

    private func spawnAll(screenSize: CGSize) {
        let w = Float(screenSize.width)
        let h = Float(screenSize.height)
        let minDist: Float = 68.0   // minimum spacing between dandelions (pt)

        var attempts = 0
        while dandelions.count < Self.count, attempts < Self.count * 40 {
            attempts += 1

            // Spread across the visible field, keeping away from the very top/bottom.
            let x = rng.nextFloat(in: w * 0.06 ... w * 0.94)
            let y = rng.nextFloat(in: h * 0.28 ... h * 0.78)
            let pos = SIMD2<Float>(x, y)

            // Reject positions that are too close to an existing dandelion.
            let tooClose = dandelions.contains {
                let dx = $0.rootPosition.x - pos.x
                let dy = $0.rootPosition.y - pos.y
                return (dx * dx + dy * dy).squareRoot() < minDist
            }
            guard !tooClose else { continue }

            dandelions.append(DandelionBlade(
                id:            dandelions.count,
                rootPosition:  pos,
                height:        rng.nextFloat(in: 102 ... 146),   // +20 % taller
                puffRadius:    rng.nextFloat(in: 26 ... 38),      // +20 % wider
                windPhase:     rng.nextFloat(in: 0 ..< .pi * 2),
                colourVariant: rng.nextFloat(in: 0 ... 1),
                rotation:      rng.nextFloat(in: 0 ..< .pi * 2)  // random screen-space facing
            ))
        }
    }

    // MARK: - Per-Frame Update

    func update(deltaTime dt: Float) {
        // Spring-back: bend angles decay toward zero each frame.
        let decayFactor = max(0.0, 1.0 - Self.springBackRate * dt)
        for i in dandelions.indices {
            dandelions[i].bendAngle *= decayFactor
            if abs(dandelions[i].bendAngle) < 0.001 { dandelions[i].bendAngle = 0 }
        }
        rebuildInstanceData()
    }

    // MARK: - Touch Interaction

    /// Bends dandelion stems near the touch point away from the finger.
    func touchMoved(at point: CGPoint) {
        let px = Float(point.x)
        let py = Float(point.y)

        for i in dandelions.indices {
            let dx = dandelions[i].rootPosition.x - px
            let dy = dandelions[i].rootPosition.y - py
            let dist = (dx * dx + dy * dy).squareRoot()
            guard dist < Self.touchRadius else { continue }

            let t = 1.0 - dist / Self.touchRadius
            let dir: Float = dist > 1.0 ? dx / dist : 0
            // Quadratic falloff: strong at contact, gentle at radius edge.
            dandelions[i].bendAngle = dir * t * t * Self.maxTouchBend
        }
    }

    // MARK: - Private helpers

    private func rebuildInstanceData() {
        instanceData = dandelions.map { $0.instanceData() }
    }
}

// MARK: - DandelionBlade model

private struct DandelionBlade {
    let id:            Int
    let rootPosition:  SIMD2<Float>
    let height:        Float          // stem height in points
    let puffRadius:    Float          // sphere radius in points
    let windPhase:     Float          // phase offset for per-dandelion wind timing
    let colourVariant: Float          // subtle green shade variation [0, 1]
    let rotation:      Float          // screen-space facing angle (radians)
    var bendAngle:     Float = 0      // touch-driven extra bend (radians)
    var seedOpacity:   Float = 1.0    // future: seeds blow away under strong wind

    func instanceData() -> DandelionInstanceData {
        DandelionInstanceData(
            rootPosition:  rootPosition,
            height:        height,
            puffRadius:    puffRadius,
            bendAngle:     bendAngle,
            windPhase:     windPhase,
            colourVariant: colourVariant,
            seedOpacity:   seedOpacity,
            rotation:      rotation
        )
    }
}

// MARK: - Seeded RNG (xorshift64)

private struct DandelionRNG {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 1 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func nextFloat() -> Float {
        Float(next() & 0x00FF_FFFF) / Float(0x00FF_FFFF)
    }

    mutating func nextFloat(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + nextFloat() * (range.upperBound - range.lowerBound)
    }

    mutating func nextFloat(in range: Range<Float>) -> Float {
        range.lowerBound + nextFloat() * (range.upperBound - range.lowerBound)
    }
}
