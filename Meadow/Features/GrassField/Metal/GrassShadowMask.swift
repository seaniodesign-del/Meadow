import CoreGraphics
import Metal

/// Renders the dual-tree shadow silhouettes into a ¼-resolution Metal texture
/// each time the time-of-day changes meaningfully. The texture (`.r8Unorm`) is
/// sampled by `grassFragment` to darken individual grass blades, replacing the
/// flat `TreeShadowView` SwiftUI overlay and giving the shadow realistic
/// integration with the grass lighting model.
///
/// Shadow math mirrors `TreeShadowView` exactly so both systems produce the
/// same silhouette shape, slant, and opacity curves.
@MainActor
final class GrassShadowMask {

    // MARK: - Public

    /// The Metal texture — `.r8Unorm`, ¼ screen resolution.
    /// Always non-nil after the first `update` call when a valid `MTLDevice`
    /// is available.
    private(set) var texture: (any MTLTexture)?

    // MARK: - Private state

    private var lastTime:       Double = -999
    private var lastScreenSize: CGSize = .zero

    /// Texture resolution is ¼ of screen size. The separable box blur applied
    /// after rasterisation hides the low resolution while keeping CPU cost minimal.
    private static let texScale: CGFloat = 0.25

    // MARK: - Shadow geometry constants (mirror TreeShadowView / GrassShadowMask)

    private let svgH:     CGFloat = 885
    private let svgBaseX: CGFloat = 436

    // MARK: - Update

    /// Call every frame from `GrassRenderer.draw(in:)`.
    /// The method is cheap to call frequently — it skips re-rendering unless
    /// `timeOfDay` has changed by more than ≈ 3.6 seconds of real time or
    /// the screen dimensions changed.
    func update(timeOfDay: Double, screenSize: CGSize, device: any MTLDevice) {
        let texW = max(4, Int(screenSize.width  * Self.texScale))
        let texH = max(4, Int(screenSize.height * Self.texScale))

        // (Re-)create the Metal texture when nil or after a screen-size change.
        if texture == nil || texture!.width != texW || texture!.height != texH {
            let desc         = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm, width: texW, height: texH, mipmapped: false)
            desc.usage       = [.shaderRead]
            desc.storageMode = .shared
            texture          = device.makeTexture(descriptor: desc)
            texture?.label   = "GrassShadowMask"
            // Force a full re-render on the next check.
            lastTime       = -999
            lastScreenSize = .zero
        }

        // Skip re-rendering if nothing relevant changed.
        guard abs(timeOfDay - lastTime) > 0.001 || screenSize != lastScreenSize else { return }
        lastTime       = timeOfDay
        lastScreenSize = screenSize

        guard let texture else { return }

        // Rasterise into a CPU pixel buffer then upload to the GPU texture.
        var pixels = [UInt8](repeating: 0, count: texW * texH)
        renderShadow(into: &pixels, texW: texW, texH: texH,
                     timeOfDay: timeOfDay, screenSize: screenSize)
        texture.replace(
            region:      MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                                   size:   .init(width: texW, height: texH, depth: 1)),
            mipmapLevel: 0,
            withBytes:   pixels,
            bytesPerRow: texW
        )
    }

    // MARK: - Shadow rasterisation

    private func renderShadow(into pixels: inout [UInt8],
                               texW: Int, texH: Int,
                               timeOfDay: Double, screenSize: CGSize) {
        pixels.withUnsafeMutableBytes { buf in
            guard let ptr = buf.baseAddress else { return }
            guard let ctx = CGContext(
                data:             ptr,
                width:            texW,
                height:           texH,
                bitsPerComponent: 8,
                bytesPerRow:      texW,
                space:            CGColorSpaceCreateDeviceGray(),
                bitmapInfo:       CGImageAlphaInfo.none.rawValue
            ) else { return }

            // Clear to black — zero shadow everywhere.
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: texW, height: texH))

            // Flip Y so the coordinate space matches screen-space (y = 0 at top).
            // CGContext default is y-up; Metal textures are read top-to-bottom.
            // After this transform, drawing at (sx, sy) in screen points maps
            // to the correct texel row.
            ctx.translateBy(x: 0, y: CGFloat(texH))
            ctx.scaleBy(x: Self.texScale, y: -Self.texScale)

            let slantX = shadowSlantX(tod: timeOfDay)

            // ── Morning shadow (right-side tree, crown sweeps leftward) ─────────
            let mOp = morningOpacity(tod: timeOfDay)
            if mOp > 0.005 {
                let t = shadowTransform(size: screenSize, slantX: slantX,
                                        anchorXFraction: 0.82, mirrored: false)
                ctx.saveGState()
                ctx.concatenate(t)
                ctx.setFillColor(gray: CGFloat(mOp), alpha: 1)
                ctx.addPath(SVGTreeShadow.cgPath)
                ctx.fillPath()
                ctx.restoreGState()
            }

            // ── Afternoon shadow (left-side tree, mirrored) ──────────────────────
            // Lighten blend: overlapping shadows take the stronger value instead of
            // double-darkening during the brief mid-day crossover window.
            let aOp = afternoonOpacity(tod: timeOfDay)
            if aOp > 0.005 {
                let t = shadowTransform(size: screenSize, slantX: slantX,
                                        anchorXFraction: 0.18, mirrored: true)
                ctx.saveGState()
                ctx.setBlendMode(.lighten)
                ctx.concatenate(t)
                ctx.setFillColor(gray: CGFloat(aOp), alpha: 1)
                ctx.addPath(SVGTreeShadow.cgPath)
                ctx.fillPath()
                ctx.restoreGState()
            }
        }

        // 3-pass separable box blur → soft penumbra edges.
        // Radius 3 in texture pixels ≈ 12 screen-point spread at ¼ scale.
        blurInPlace(&pixels, width: texW, height: texH, radius: 3)
    }

    // MARK: - Box blur

    private func blurInPlace(_ p: inout [UInt8], width: Int, height: Int, radius: Int) {
        guard radius > 0 else { return }
        for _ in 0..<3 {
            boxBlurH(&p, w: width, h: height, r: radius)
            boxBlurV(&p, w: width, h: height, r: radius)
        }
    }

    private func boxBlurH(_ p: inout [UInt8], w: Int, h: Int, r: Int) {
        let diam = 2 * r + 1
        var out  = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            var sum = 0
            for i in -r...r { sum += Int(p[y * w + clamp(i, 0, w - 1)]) }
            for x in 0..<w {
                out[y * w + x] = UInt8(sum / diam)
                sum += Int(p[y * w + clamp(x + r + 1, 0, w - 1)])
                    -  Int(p[y * w + clamp(x - r,     0, w - 1)])
            }
        }
        p = out
    }

    private func boxBlurV(_ p: inout [UInt8], w: Int, h: Int, r: Int) {
        let diam = 2 * r + 1
        var out  = [UInt8](repeating: 0, count: w * h)
        for x in 0..<w {
            var sum = 0
            for i in -r...r { sum += Int(p[clamp(i, 0, h - 1) * w + x]) }
            for y in 0..<h {
                out[y * w + x] = UInt8(sum / diam)
                sum += Int(p[clamp(y + r + 1, 0, h - 1) * w + x])
                    -  Int(p[clamp(y - r,      0, h - 1) * w + x])
            }
        }
        p = out
    }

    @inline(__always)
    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        Swift.max(lo, Swift.min(hi, v))
    }

    // MARK: - Shadow math (mirrors TreeShadowView exactly)

    private func morningOpacity(tod: Double) -> Double {
        smoothstep(5.5, 7.5, tod) * (1 - smoothstep(11.5, 13.5, tod)) * 0.55
    }

    private func afternoonOpacity(tod: Double) -> Double {
        smoothstep(12.5, 14.5, tod) * (1 - smoothstep(20.5, 22.0, tod)) * 0.55
    }

    private func shadowSlantX(tod: Double) -> CGFloat {
        CGFloat(Swift.max(-2.8, Swift.min(2.8, (tod - 13.0) / 3.2)))
    }

    private func shadowTransform(size: CGSize,
                                  slantX: CGFloat,
                                  anchorXFraction: CGFloat,
                                  mirrored: Bool) -> CGAffineTransform {
        let scale   = size.height / svgH
        let anchorX = size.width * anchorXFraction
        let ty      = size.height - scale * svgH
        if mirrored {
            // tx solves: −scale·svgBaseX − slantX·scale·svgH + tx = anchorX
            let tx = anchorX + scale * svgBaseX + slantX * scale * svgH
            return CGAffineTransform(a: -scale, b: 0,
                                     c: -slantX * scale, d: scale,
                                     tx: tx, ty: ty)
        } else {
            // tx solves: scale·svgBaseX − slantX·scale·svgH + tx = anchorX
            let tx = anchorX - scale * svgBaseX + slantX * scale * svgH
            return CGAffineTransform(a: scale, b: 0,
                                     c: -slantX * scale, d: scale,
                                     tx: tx, ty: ty)
        }
    }

    private func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = Swift.max(0, Swift.min(1, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }
}
