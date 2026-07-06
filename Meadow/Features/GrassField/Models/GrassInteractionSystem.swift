import Foundation
import simd

/// Drives the three grass interaction effects (Ripple, Foot step, Star).
///
/// All three express themselves through the **same per-blade bend angle** the
/// grass vertex shader already consumes for touch and wind. Each frame the
/// view model zeroes the bend array and asks this system to add its
/// contributions, so effects layer naturally on top of the wind animation and
/// return to rest automatically once a front passes or a footstep fades.
///
/// Screen-space convention matches `GrassBlade.rootPosition`: points, origin at
/// the top-left, +y downward. A positive bend leans a blade toward +x (right),
/// so a blade is pushed *outward* from a centre `c` by `amplitude * (dx / dist)`.
@MainActor
final class GrassInteractionSystem {

    // MARK: - Effect records

    /// An expanding circular (Ripple) or star-shaped (Star) bend front.
    private struct Front {
        var center: SIMD2<Float>
        var age: Float = 0
        let isStar: Bool
        let maxRadius: Float      // front travels until it exceeds this, then removed
    }

    /// A single pressed-grass footprint, oriented along the walking direction.
    private struct Footprint {
        var center: SIMD2<Float>
        let dirAngle: Float       // walking direction (radians)
        var age: Float = 0
    }

    // MARK: - Tuning

    private enum K {
        // Front (Ripple / Star)
        static let frontSpeed:  Float = 560      // pt/s — radius growth rate (slower = reads as expansion)
        static let frontBand:   Float = 150      // pt — half-width of the disturbed ring (thicker = bolder)
        static let frontAmp:    Float = 1.44     // rad — peak lean at the ring crest (−20% from 1.8)
        /// Minimum fraction of the radial lean applied even where the radial
        /// direction is near-vertical (dx≈0). Blades only bend along screen-x,
        /// so without this floor the ring would vanish at its top & bottom.
        static let frontDirFloor: Float = 0.62
        static let starPoints:  Float = 5
        static let starDepth:   Float = 0.42     // 0 = circle, →1 = spikier star
        static let starSpin:    Float = 0.7      // rad/s — slow rotation while expanding
        static let ringStagger: Float = 0.16     // s between concentric rings in a tap burst

        // Foot step
        // Prints must be spaced FURTHER apart than their own size or they merge
        // into one continuous streak (reads as a single foot). strideLen > full
        // length (2·footLen) keeps consecutive prints distinct along the path;
        // lateral ≈ full width (2·footWid) keeps the L/R zigzag clearly staggered.
        static let strideLen:   Float = 66       // pt of finger travel between prints (> 2·footLen)
        static let lateral:     Float = 23       // pt — left/right offset, alternating each print
        static let footLen:     Float = 28       // pt — print half-length along travel (elongated, foot-like)
        static let footWid:     Float = 14       // pt — print half-width across travel
        static let pressAmp:    Float = 1.9      // rad — how flat blades are pressed (lays them over)
        static let footLife:    Float = 3.8      // s — lifetime; longer so the whole staggered trail shows
        static let footFadeIn:  Float = 0.12     // s
        static let footFadeOut: Float = 0.9      // s — trailing fade window
        static let maxPrints:   Int   = 10       // 5 pairs

        static let bendClamp:   Float = 1.95     // rad — final per-blade safety clamp
    }

    // MARK: - State

    private var fronts: [Front] = []
    private var footprints: [Footprint] = []

    // Footstep trail tracking
    private var lastStamp: SIMD2<Float>?
    private var parity: Int = 0

    /// True while any effect is still producing bend — lets the view model skip
    /// the per-blade zero/apply pass when the field is at rest.
    var isActive: Bool { !fronts.isEmpty || !footprints.isEmpty }

    // MARK: - Spawning

    /// Spawn `rings` concentric fronts from `center`, staggered in time so a
    /// single tap reads as a real multi-ring ripple rather than one fleeting
    /// band. Later rings start with a negative age (dormant until they "fire").
    func spawnFront(at center: SIMD2<Float>, isStar: Bool, screenSize: CGSize, rings: Int = 1) {
        let w = Float(screenSize.width), h = Float(screenSize.height)
        // Farthest reachable point is a screen corner; pad so the front fully
        // clears the visible boundary before removal.
        let diag = (w * w + h * h).squareRoot()
        let count = max(1, rings)
        for k in 0..<count {
            fronts.append(Front(center: center,
                                age: -Float(k) * K.ringStagger,
                                isStar: isStar,
                                maxRadius: diag * 1.08))
        }
    }

    func beginFootsteps(at point: SIMD2<Float>) {
        lastStamp = point
        parity = 0
        // Drop the first print immediately so a tap-and-hold shows something.
        stampFootprint(at: point, dirAngle: 0)
    }

    /// Advance the footstep trail toward `point`. Returns the number of new
    /// prints stamped this move (the view model fires one haptic tick each).
    @discardableResult
    func moveFootsteps(to point: SIMD2<Float>) -> Int {
        guard var from = lastStamp else {
            lastStamp = point
            return 0
        }
        var stamped = 0
        var travel = point - from
        var dist = simd_length(travel)
        // Lay prints at fixed stride intervals along the path so speed doesn't
        // change spacing — alternating left/right of the direction of travel.
        while dist >= K.strideLen {
            let dir = travel / dist
            let step = from + dir * K.strideLen
            let dirAngle = atan2(dir.y, dir.x)
            // Perpendicular offset, alternating each print.
            let perp = SIMD2<Float>(-dir.y, dir.x) * (parity % 2 == 0 ? K.lateral : -K.lateral)
            stampFootprint(at: step + perp, dirAngle: dirAngle)
            parity += 1
            stamped += 1
            from = step
            travel = point - from
            dist = simd_length(travel)
        }
        lastStamp = from
        return stamped
    }

    func endFootsteps() {
        lastStamp = nil
    }

    private func stampFootprint(at center: SIMD2<Float>, dirAngle: Float) {
        footprints.append(Footprint(center: center, dirAngle: dirAngle))
        // Cap to 5 pairs: drop the oldest so the path "disappears" behind you.
        if footprints.count > K.maxPrints {
            footprints.removeFirst(footprints.count - K.maxPrints)
        }
    }

    /// Clear all effects and trail state (called on mode change).
    func reset() {
        fronts.removeAll()
        footprints.removeAll()
        lastStamp = nil
        parity = 0
    }

    // MARK: - Per-frame update

    func update(deltaTime dt: Float) {
        for i in fronts.indices { fronts[i].age += dt }
        fronts.removeAll { K.frontSpeed * $0.age - K.frontBand > $0.maxRadius }

        for i in footprints.indices { footprints[i].age += dt }
        footprints.removeAll { $0.age >= K.footLife }
    }

    // MARK: - Bend application

    /// Add every active effect's contribution into `out` (parallel to `blades`).
    /// `out` is expected to be pre-zeroed by the caller.
    func applyBends(blades: [GrassBlade], into out: inout [Float]) {
        guard out.count == blades.count else { return }
        applyFronts(blades: blades, into: &out)
        applyFootprints(blades: blades, into: &out)
        for i in out.indices { out[i] = out[i].clamped(to: -K.bendClamp...K.bendClamp) }
    }

    private func applyFronts(blades: [GrassBlade], into out: inout [Float]) {
        for front in fronts {
            let radius = K.frontSpeed * front.age
            // Dormant ring (negative age in a staggered burst) — not firing yet.
            guard radius > 0 else { continue }
            // Dissipate as the ring expands so it fades toward the edges.
            let envelope = max(0, min(1, 1 - radius / front.maxRadius))
            guard envelope > 0 else { continue }

            // Cheap annulus cull bounds: only blades whose distance falls within
            // [radius - band, radius + band] can be disturbed.
            let outer = radius + K.frontBand
            let inner = max(0, radius - K.frontBand)
            let outer2 = outer * outer
            let inner2 = inner * inner
            let spin = front.isStar ? front.age * K.starSpin : 0

            for i in blades.indices {
                let c = front.center
                let dx = blades[i].rootPosition.x - c.x
                let dy = blades[i].rootPosition.y - c.y
                let d2 = dx * dx + dy * dy
                if d2 > outer2 || d2 < inner2 { continue }
                let dist = d2.squareRoot()
                if dist < 1 { continue }

                // Star: modulate the effective front radius by blade angle so the
                // ring grows points and valleys; circle: constant radius.
                var frontR = radius
                if front.isStar {
                    let ang = atan2(dy, dx)
                    frontR = radius * (1 + K.starDepth * cos(K.starPoints * ang + spin))
                }

                let diff = abs(dist - frontR)
                if diff >= K.frontBand { continue }

                let crest = 1 - diff / K.frontBand          // 0…1, peak at the front
                let amp = K.frontAmp * crest * crest * envelope * blades[i].resistanceCoefficient
                // Lean radially outward. Floor the magnitude (keeping the radial
                // sign) so the ring stays continuous even near its top & bottom,
                // where the pure radial dx/dist would otherwise fade to zero.
                let radial = dx / dist                      // −1…1, sign = side of centre
                let mag = max(K.frontDirFloor, abs(radial))
                out[i] += amp * mag * (radial < 0 ? -1 : 1)
            }
        }
    }

    private func applyFootprints(blades: [GrassBlade], into out: inout [Float]) {
        let cullR = max(K.footLen, K.footWid)
        let cullR2 = cullR * cullR
        for print in footprints {
            let life = footprintLife(print.age)
            guard life > 0 else { continue }
            let fwd = SIMD2<Float>(cos(print.dirAngle), sin(print.dirAngle))
            let side = SIMD2<Float>(-fwd.y, fwd.x)
            // Press blades flat with a constant strong magnitude — the elliptical
            // footprint shape (oriented by fwd/side below) conveys the walking
            // direction, so the bend itself just needs to flatten the patch.
            // (A direction-dependent press would vanish for vertical walks, since
            // blades only bend along screen-x.)
            let press = K.pressAmp * life

            for i in blades.indices {
                let rel = blades[i].rootPosition - print.center
                if simd_length_squared(rel) > cullR2 { continue }
                // Elliptical falloff in the footprint's local frame.
                let u = simd_dot(rel, fwd) / K.footLen
                let v = simd_dot(rel, side) / K.footWid
                let e = u * u + v * v
                if e >= 1 { continue }
                out[i] += press * (1 - e) * blades[i].resistanceCoefficient
            }
        }
    }

    /// Fade-in then trailing fade-out envelope for a single footprint.
    private func footprintLife(_ age: Float) -> Float {
        let fadeIn  = smoothstep(0, K.footFadeIn, age)
        let fadeOut = 1 - smoothstep(K.footLife - K.footFadeOut, K.footLife, age)
        return max(0, fadeIn * fadeOut)
    }
}

// MARK: - Small math helpers

private func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
    let t = ((x - edge0) / (edge1 - edge0)).clamped(to: 0...1)
    return t * t * (3 - 2 * t)
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
