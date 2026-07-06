import Foundation

/// Classic 2D Perlin noise, seeded for deterministic grass layout.
struct PerlinNoise {
    private let permutation: [Int]

    init(seed: Int = 0) {
        var p = Array(0..<256)
        var rng = SeededRNG(seed: seed)
        for i in stride(from: 255, through: 1, by: -1) {
            let j = rng.next() % (i + 1)
            p.swapAt(i, j)
        }
        permutation = p + p  // double for wrap-around
    }

    func value(x: Float, y: Float) -> Float {
        let xi = Int(floor(x)) & 255
        let yi = Int(floor(y)) & 255
        let xf = x - floor(x)
        let yf = y - floor(y)

        let u = fade(xf)
        let v = fade(yf)

        let aa = permutation[permutation[xi]     + yi]
        let ab = permutation[permutation[xi]     + yi + 1]
        let ba = permutation[permutation[xi + 1] + yi]
        let bb = permutation[permutation[xi + 1] + yi + 1]

        let x1 = lerp(a: grad(hash: aa, x: xf,       y: yf),
                      b: grad(hash: ba, x: xf - 1.0, y: yf),       t: u)
        let x2 = lerp(a: grad(hash: ab, x: xf,       y: yf - 1.0),
                      b: grad(hash: bb, x: xf - 1.0, y: yf - 1.0), t: u)

        return lerp(a: x1, b: x2, t: v)  // returns -1..1
    }

    /// Returns 0..1 (remapped)
    func normalised(x: Float, y: Float) -> Float {
        (value(x: x, y: y) + 1.0) * 0.5
    }

    private func fade(_ t: Float) -> Float { t * t * t * (t * (t * 6 - 15) + 10) }
    private func lerp(a: Float, b: Float, t: Float) -> Float { a + t * (b - a) }
    private func grad(hash: Int, x: Float, y: Float) -> Float {
        switch hash & 3 {
        case 0:  return  x + y
        case 1:  return -x + y
        case 2:  return  x - y
        default: return -x - y
        }
    }
}

private struct SeededRNG {
    private var state: Int
    init(seed: Int) { state = seed == 0 ? 1 : seed }
    mutating func next() -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return abs(state)
    }
}
