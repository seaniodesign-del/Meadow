import SwiftUI

/// Renders time-accurate tree shadows by drawing the pre-parsed SVG path
/// (from `SVGTreeShadow.swift`) in a SwiftUI `Canvas`.
///
/// Two shadows are composited to give full-day coverage:
///
///   **Morning shadow** (right-side tree, 5:30–13:30)
///   - Anchor at 82 % of screen width (bottom-right)
///   - Negative `slantX` → crown extends leftward
///
///   **Afternoon shadow** (left-side tree, mirrored, 12:30–22:00)
///   - Anchor at 18 % of screen width (bottom-left)
///   - Horizontally flipped SVG + positive `slantX` → crown extends rightward
///
/// Both use the same `Subtract.svg` silhouette scaled to screen height.
/// Shadow colour: dark green-black matching the Metal grass shadow palette.
@MainActor
struct TreeShadowView: View {

    let timeOfDay: Double   // clock hour in [0, 24)

    // SVG viewBox — must match the values in SVGTreeShadow.swift
    private let svgW: CGFloat = 872
    private let svgH: CGFloat = 885

    // SVG x-coordinate of the tree-base centre (horizontal mid of the trunk)
    private let svgBaseX: CGFloat = 436

    // Dark green-black: matches the grass/leaf shadow palette in the Metal renderer
    // (r≈0.005, g≈0.02, b≈0.003 at full opacity)
    private let shadowColor = Color(red: 0.005, green: 0.018, blue: 0.003)

    var body: some View {
        Canvas { context, size in
            // ── Morning shadow (right tree, crown sweeps leftward) ────────────
            let morningOp = morningOpacity(tod: timeOfDay)
            if morningOp > 0.005 {
                var ctx = context
                ctx.opacity = morningOp
                ctx.transform = shadowTransform(
                    size: size,
                    slantX: shadowSlantX(tod: timeOfDay),
                    anchorXFraction: 0.82,
                    mirrored: false
                )
                ctx.fill(SVGTreeShadow.swiftUIPath, with: .color(shadowColor))
            }

            // ── Afternoon shadow (left tree, mirrored, crown sweeps rightward) ─
            let afternoonOp = afternoonOpacity(tod: timeOfDay)
            if afternoonOp > 0.005 {
                var ctx = context
                ctx.opacity = afternoonOp
                ctx.transform = shadowTransform(
                    size: size,
                    slantX: shadowSlantX(tod: timeOfDay),
                    anchorXFraction: 0.18,
                    mirrored: true
                )
                ctx.fill(SVGTreeShadow.swiftUIPath, with: .color(shadowColor))
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    // MARK: - Opacity curves

    /// Morning tree: ramps in at dawn, fades through solar noon.
    private func morningOpacity(tod: Double) -> Double {
        let appear = smoothstep(5.5, 7.5, tod)
        let vanish = 1 - smoothstep(11.5, 13.5, tod)
        return appear * vanish * 0.55
    }

    /// Afternoon tree: fades in after solar noon, ramps out at dusk.
    private func afternoonOpacity(tod: Double) -> Double {
        let appear = smoothstep(12.5, 14.5, tod)
        let vanish = 1 - smoothstep(20.5, 22.0, tod)
        return appear * vanish * 0.55
    }

    // MARK: - Horizontal shear

    /// Positive = shadow leans right (afternoon, sun from the west).
    /// Negative = shadow leans left  (morning,   sun from the east).
    private func shadowSlantX(tod: Double) -> CGFloat {
        let raw = (tod - 13.0) / 3.2
        return CGFloat(max(-2.8, min(2.8, raw)))
    }

    // MARK: - Transform

    /// Builds the CGAffineTransform that maps the 872 × 885 SVG path into
    /// screen space, anchoring the tree base at the specified horizontal fraction.
    ///
    /// **Normal (mirrored: false)**
    ///   screenX = scale · svgX  −  slantX · scale · svgY  +  tx
    ///   screenY = scale · svgY  +  ty
    ///
    /// **Mirrored (mirrored: true)**  — horizontal flip, tree on left side
    ///   screenX = −scale · svgX  −  slantX · scale · svgY  +  tx′
    ///   screenY =  scale · svgY  +  ty
    ///
    /// In both cases the tree base (svgBaseX, svgH) anchors to
    /// (size.width · anchorXFraction, size.height).
    private func shadowTransform(
        size: CGSize,
        slantX: CGFloat,
        anchorXFraction: CGFloat,
        mirrored: Bool
    ) -> CGAffineTransform {
        let scale: CGFloat = size.height / svgH
        let anchorX = size.width * anchorXFraction
        let anchorY = size.height
        let ty = anchorY - scale * svgH

        if mirrored {
            // Solve: −scale·svgBaseX − slantX·scale·svgH + tx = anchorX
            let tx = anchorX + scale * svgBaseX + slantX * scale * svgH
            return CGAffineTransform(
                a:  -scale,
                b:   0,
                c:  -slantX * scale,
                d:   scale,
                tx:  tx,
                ty:  ty
            )
        } else {
            // Solve: scale·svgBaseX − slantX·scale·svgH + tx = anchorX   (wait, verify sign)
            // anchorX = scale·svgBaseX + (−slantX·scale)·svgH + tx
            // tx = anchorX − scale·svgBaseX + slantX·scale·svgH
            let tx = anchorX - scale * svgBaseX + slantX * scale * svgH
            return CGAffineTransform(
                a:   scale,
                b:   0,
                c:  -slantX * scale,
                d:   scale,
                tx:  tx,
                ty:  ty
            )
        }
    }

    // MARK: - Helpers

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}
