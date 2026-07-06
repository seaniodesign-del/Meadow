import Foundation
import simd

/// Generates the static grass blade layout. Designed to run off main thread.
/// All inputs are value types; no UIKit/AppKit dependencies.
enum GrassFieldGenerator {
    static func generate(
        density: GrassSettings.GrassDensity,
        bladeHeight: GrassSettings.BladeHeight,
        screenSize: CGSize,
        seed: Int
    ) -> [GrassBlade] {
        let noise = PerlinNoise(seed: seed)
        var rng = SeededRandom(seed: seed &+ 1)

        let cellSize: Float = 8.0
        let cols = Int(ceil(Float(screenSize.width)  / cellSize)) + 1
        let rows = Int(ceil(Float(screenSize.height) / cellSize)) + 1

        let target = density.bladeCount
        var blades = [GrassBlade]()
        blades.reserveCapacity(target)

        let heightMult = bladeHeight.heightMultiplier

        // Build a shuffled list of all cell coordinates so that when we break
        // after `target` blades, those blades are spread uniformly across the
        // whole field — not clustered at the top of a top-to-bottom scan.
        var cells = [(row: Int, col: Int)]()
        cells.reserveCapacity(rows * cols)
        for row in 0..<rows {
            for col in 0..<cols { cells.append((row, col)) }
        }
        for i in stride(from: cells.count - 1, through: 1, by: -1) {
            cells.swapAt(i, rng.nextInt(in: 0...i))
        }

        for (row, col) in cells {
            if blades.count >= target { break }
            let baseX = Float(col) * cellSize
            let baseY = Float(row) * cellSize

            // Perlin-based local density: 0..1
            let densityFactor = noise.normalised(x: baseX / 80, y: baseY / 80)
            let bladesInCell: Int
            if densityFactor > 0.25      { bladesInCell = rng.nextInt(in: 1...4) }
            else if densityFactor > 0.10 { bladesInCell = rng.nextInt(in: 1...2) }
            else                         { bladesInCell = 0 }

            for _ in 0..<bladesInCell {
                if blades.count >= target { break }

                let x = baseX + rng.nextFloat(in: 0..<cellSize)
                let y = baseY + rng.nextFloat(in: 0..<cellSize)

                let sizeRoll = rng.nextFloat()
                let sizeClass: GrassBlade.SizeClass
                let heightRange: ClosedRange<Float>
                if sizeRoll < 0.35 {
                    sizeClass = .short;  heightRange = 10...18
                } else if sizeRoll < 0.72 {
                    sizeClass = .medium; heightRange = 18...28
                } else {
                    sizeClass = .tall;   heightRange = 28...42
                }

                blades.append(GrassBlade(
                    id: UUID(),
                    rootPosition: SIMD2<Float>(x, y),
                    height: rng.nextFloat(in: heightRange) * heightMult,
                    baseWidth: rng.nextFloat(in: 2.5...5.0),   // wide for continuous coverage
                    baseTilt: rng.nextFloat(in: -0.50...0.50), // ±29° of random lean
                    colourVariant: rng.nextFloat(),
                    resistanceCoefficient: rng.nextFloat(in: 0.7...1.3),
                    sizeClass: sizeClass
                ))
            }
        }

        // Depth sort: back-to-front (smaller Y = further from camera in top-down view)
        return blades.sorted { $0.rootPosition.y < $1.rootPosition.y }
    }
}

// MARK: - Seeded deterministic RNG (xorshift64)

private struct SeededRandom {
    private var state: UInt64

    init(seed: Int) {
        state = seed == 0 ? 6364136223846793005 : UInt64(bitPattern: Int64(seed))
    }

    mutating func nextUInt64() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func nextFloat() -> Float {
        Float(nextUInt64() & 0x00FF_FFFF) / Float(0x00FF_FFFF)
    }

    mutating func nextFloat(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + nextFloat() * (range.upperBound - range.lowerBound)
    }

    mutating func nextFloat(in range: Range<Float>) -> Float {
        range.lowerBound + nextFloat() * (range.upperBound - range.lowerBound)
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(nextUInt64() % UInt64(range.upperBound - range.lowerBound + 1))
    }
}
