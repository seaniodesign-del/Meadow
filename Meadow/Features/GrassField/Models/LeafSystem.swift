import Foundation
import simd

/// Manages all fallen / airborne autumn leaves.
///
/// Leaves spawn off the top edge and drift downward under gravity and wind.
/// Once grounded they stay put until a touch scatters them back into the air.
/// Call `update(deltaTime:windAmplitude:)` every frame and read `instanceData`
/// to upload to the GPU.
@MainActor
final class LeafSystem {

    // MARK: - Constants
    private static let leafCount: Int  = 180
    private static let gravity: Float  = 160.0   // pt/s²
    private static let drag: Float     = 2.2      // linear drag coefficient (1/s)
    private static let angularDrag: Float = 1.8   // angular drag (1/s)
    private static let scatterRadius: Float = 70.0
    private static let scatterStrength: Float = 40.0

    // MARK: - Public

    /// Combined instance array: resting leaves first (indices 0..<floorLeafCount),
    /// then falling leaves (indices floorLeafCount..<floorLeafCount+airLeafCount).
    /// Within each group, sorted back-to-front by Y.
    /// The renderer issues two draw calls from this single buffer so resting leaves
    /// are drawn BEFORE the grass pass (grass occludes them) and falling leaves AFTER.
    private(set) var instanceData: [LeafInstanceData] = []
    private(set) var floorLeafCount: Int = 0   // resting — rendered under grass
    private(set) var airLeafCount:   Int = 0   // falling — rendered over grass

    // MARK: - Private
    private var leaves: [FallenLeaf] = []
    private var rng: LeafRNG

    // MARK: - Init

    init(screenSize: CGSize) {
        rng = LeafRNG(seed: 0xA37B_2F91)
        leaves.reserveCapacity(Self.leafCount)
        spawnAll(screenSize: screenSize)
        rebuildInstanceData()
    }

    // MARK: - Spawn

    private func spawnAll(screenSize: CGSize) {
        let w = Float(screenSize.width)
        let h = Float(screenSize.height)

        for i in 0..<Self.leafCount {
            // Mix of already-resting leaves (bottom 55%) and falling ones (top 45%).
            let isResting = rng.nextFloat() < 0.60

            let x: Float = rng.nextFloat(in: 0..<w)
            let y: Float

            if isResting {
                // Scatter resting leaves across most of the field so the full
                // grass area has leaves, not just the bottom portion.
                y = h * rng.nextFloat(in: 0.10...1.00)
            } else {
                // Start falling leaves above or near the top edge.
                y = rng.nextFloat(in: -80.0...h * 0.30)
            }

            let leaf = FallenLeaf(
                id:             i,
                textureIndex:   UInt32(rng.nextInt(in: 0...6)),
                brightness:     rng.nextFloat(in: 0.72...1.08),
                baseScale:      rng.nextFloat(in: 40.8...74.4),
                windPhase:      rng.nextFloat(in: 0..<(.pi * 2)),
                position:       SIMD2(x, y),
                velocity:       isResting ? .zero : SIMD2(
                    rng.nextFloat(in: -25.0...25.0),
                    rng.nextFloat(in: 20.0...60.0)
                ),
                rotation:       rng.nextFloat(in: 0..<(.pi * 2)),
                angularVelocity: isResting ? 0.0 : rng.nextFloat(in: -3.0...3.0),
                tilt:           isResting
                                    ? rng.nextFloat(in: -0.25...0.25)
                                    : rng.nextFloat(in: -Float.pi...Float.pi),
                tiltVelocity:   isResting ? 0.0 : rng.nextFloat(in: -2.5...2.5),
                state:          isResting ? .resting : .falling,
                opacity:        1.0,
                groundY:        h * rng.nextFloat(in: 0.70...1.05),
                gustTimer:      rng.nextFloat(in: 8.0...40.0)
            )
            leaves.append(leaf)
        }
    }

    // MARK: - Per-Frame Update

    func update(deltaTime dt: Float, windAmplitude: Float, elapsedTime: Float, screenSize: CGSize) {
        let w = Float(screenSize.width)
        let h = Float(screenSize.height)

        for i in leaves.indices {
            switch leaves[i].state {
            case .resting:
                // Leaves resting in grass stay completely still. Only an occasional
                // wind gust can lift one briefly and carry it to a new spot.
                leaves[i].gustTimer -= dt
                if leaves[i].gustTimer <= 0 {
                    // Reschedule next check, inversely scaled by wind strength so
                    // gusty conditions produce more frequent events.
                    let baseInterval = rng.nextFloat(in: 60.0...180.0)
                    leaves[i].gustTimer = baseInterval / max(windAmplitude * 5.0, 0.1)

                    // Only lift if there is meaningful wind.
                    if windAmplitude > 0.04 {
                        let gustDir: Float = rng.nextFloat() < 0.5 ? -1.0 : 1.0
                        let speed = rng.nextFloat(in: 20.0...50.0) * windAmplitude * 3.0
                        leaves[i].velocity        = SIMD2(gustDir * speed,
                                                          -rng.nextFloat(in: 15.0...40.0))
                        leaves[i].angularVelocity = (rng.nextFloat() - 0.5) * 2.5
                        leaves[i].tiltVelocity    = (rng.nextFloat() - 0.5) * 2.0
                        leaves[i].state           = .falling
                    }
                }

            case .falling:
                // Wind force — lateral drift with per-leaf phase offset.
                let windPhase = elapsedTime * 1.1 + leaves[i].windPhase
                let windForce = sin(windPhase) * windAmplitude * 180.0

                // Gravity + wind → integrate velocity.
                leaves[i].velocity.x += windForce * dt
                leaves[i].velocity.y += Self.gravity * dt

                // Linear drag.
                let dragFactor = max(0.0, 1.0 - Self.drag * dt)
                leaves[i].velocity.x *= dragFactor
                leaves[i].velocity.y *= dragFactor

                // Clamp lateral speed to stop runaway drift.
                leaves[i].velocity.x = leaves[i].velocity.x.clamped(to: -200.0...200.0)

                // Position integration.
                leaves[i].position.x += leaves[i].velocity.x * dt
                leaves[i].position.y += leaves[i].velocity.y * dt

                // Angular (in-plane) integration + drag.
                leaves[i].rotation        += leaves[i].angularVelocity * dt
                leaves[i].angularVelocity *= max(0.0, 1.0 - Self.angularDrag * dt)

                // 3-D tilt: free tumble with gentle drag while airborne.
                leaves[i].tilt         += leaves[i].tiltVelocity * dt
                leaves[i].tiltVelocity *= max(0.0, 1.0 - 0.6 * dt)

                // Ground landing.
                if leaves[i].position.y >= leaves[i].groundY {
                    leaves[i].position.y    = leaves[i].groundY
                    leaves[i].velocity      = .zero
                    leaves[i].angularVelocity = 0
                    leaves[i].tiltVelocity  = 0
                    // Settle to a nearly-flat resting tilt (small random angle).
                    leaves[i].tilt = leaves[i].tilt.truncatingRemainder(dividingBy: .pi * 2)
                    leaves[i].state     = .resting
                    leaves[i].gustTimer = rng.nextFloat(in: 8.0...40.0)
                }

                // Wrap leaves that drift too far off-screen horizontally.
                if leaves[i].position.x < -60 { leaves[i].position.x = w + 40 }
                if leaves[i].position.x > w + 60 { leaves[i].position.x = -40 }

                // Recycle leaves that fall below the bottom edge.
                if leaves[i].position.y > h + 80 {
                    respawn(&leaves[i], screenSize: screenSize)
                }
            }
        }

        rebuildInstanceData()
    }

    // MARK: - Touch Scatter

    /// Scatter leaves near a touch point back into the air.
    func touchMoved(at point: CGPoint) {
        let px = Float(point.x)
        let py = Float(point.y)

        for i in leaves.indices {
            let dx = leaves[i].position.x - px
            let dy = leaves[i].position.y - py
            let dist = (dx * dx + dy * dy).squareRoot()
            guard dist < Self.scatterRadius else { continue }

            let t = 1.0 - dist / Self.scatterRadius
            let impulse = t * t * Self.scatterStrength

            // Direction: away from finger, with upward bias.
            let nx: Float = dist > 1.0 ? dx / dist : 0
            let ny: Float = dist > 1.0 ? dy / dist : -1.0

            leaves[i].velocity.x     += nx * impulse
            leaves[i].velocity.y     += ny * impulse - impulse * 0.2
            leaves[i].angularVelocity += (rng.nextFloat() - 0.5) * 5.0
            leaves[i].tiltVelocity   += (rng.nextFloat() - 0.5) * 3.0
            leaves[i].state           = .falling
        }
    }

    // MARK: - Private helpers

    private func rebuildInstanceData() {
        // Sort each group back-to-front independently.
        let sorted = leaves.sorted { $0.position.y < $1.position.y }
        let floor  = sorted.filter { $0.state == .resting }
        let air    = sorted.filter { $0.state == .falling }
        floorLeafCount = floor.count
        airLeafCount   = air.count
        instanceData   = floor.map { $0.instanceData() } + air.map { $0.instanceData() }
    }

    private func respawn(_ leaf: inout FallenLeaf, screenSize: CGSize) {
        let w = Float(screenSize.width)
        leaf.position        = SIMD2(rng.nextFloat(in: 0..<w), rng.nextFloat(in: -80.0...(-20.0)))
        leaf.velocity        = SIMD2(rng.nextFloat(in: -20.0...20.0), rng.nextFloat(in: 25.0...55.0))
        leaf.rotation        = rng.nextFloat(in: 0..<(.pi * 2))
        leaf.angularVelocity = rng.nextFloat(in: -2.5...2.5)
        leaf.tilt            = rng.nextFloat(in: -Float.pi...Float.pi)
        leaf.tiltVelocity    = rng.nextFloat(in: -2.5...2.5)
        leaf.state           = .falling
        leaf.opacity         = 1.0
        leaf.gustTimer       = rng.nextFloat(in: 8.0...40.0)
    }
}

// MARK: - Float clamping helper

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}

// MARK: - Seeded RNG (xorshift64 — mirrors GrassFieldGenerator's private type)

private struct LeafRNG {
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

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }
}
