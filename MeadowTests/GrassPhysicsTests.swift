import Testing
@testable import Meadow

struct GrassPhysicsTests {

    // MARK: - SpatialGrid

    @Test("SpatialGrid returns blades within radius")
    func spatialGridRadiusQuery() {
        // TODO: Phase 4.2 — create blades at known positions, verify radius query
    }

    @Test("SpatialGrid returns no blades outside radius")
    func spatialGridExcludesOutsideBlades() {
        // TODO: Phase 4.2
    }

    // MARK: - PerlinNoise

    @Test("PerlinNoise returns values in -1..1 range")
    func perlinNoiseRange() {
        let noise = PerlinNoise(seed: 42)
        for x in stride(from: 0.0 as Float, to: 10.0, by: 0.13) {
            for y in stride(from: 0.0 as Float, to: 10.0, by: 0.13) {
                let v = noise.value(x: x, y: y)
                #expect(v >= -1.0 && v <= 1.0)
            }
        }
    }

    @Test("PerlinNoise is deterministic with same seed")
    func perlinNoiseDeterminism() {
        let a = PerlinNoise(seed: 7)
        let b = PerlinNoise(seed: 7)
        #expect(a.value(x: 1.5, y: 2.3) == b.value(x: 1.5, y: 2.3))
    }

    // MARK: - SpringPhysics

    @Test("Spring recovers to zero from positive angle")
    func springRecovery() {
        // TODO: Phase 5.1 — step spring physics, verify convergence to 0
    }

    @Test("Spring overshoots before settling")
    func springOvershoot() {
        // TODO: Phase 5.1 — verify angle crosses zero before settling
    }

    // MARK: - GrassFieldGenerator

    @Test("Generator produces expected blade count for density")
    func generatorBladeCount() {
        // TODO: Phase 2.2 — verify dense/normal/sparse hit expected counts within ±10%
    }
}
