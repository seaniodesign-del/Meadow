import SwiftUI

/// Full-screen overlay that renders firefly glow effects after 8:30 PM (20:30).
///
/// The street lamp light is handled entirely in the Metal shader (GrassShaders.metal)
/// using the same radial-attenuation technique as the sunlight streaks, so it
/// affects the grass blades themselves rather than sitting above them.
///
/// This view is transparent everywhere except the firefly glows, so it can safely
/// be layered above the Metal grass canvas without obscuring anything.
struct NightAmbientView: View {

    let timeOfDay: Double

    // MARK: - Body

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                drawFireflies(ctx: ctx, size: size,
                              elapsed: context.date.timeIntervalSinceReferenceDate)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    // MARK: - Fireflies

    private static let system = FireflySystem()

    private func drawFireflies(ctx: GraphicsContext, size: CGSize, elapsed: Double) {
        for firefly in NightAmbientView.system.fireflies {
            let bright = NightAmbientView.system.brightness(
                for:       firefly,
                elapsed:   elapsed,
                timeOfDay: timeOfDay
            )
            guard bright > 0.01 else { continue }

            let cx = firefly.normalised.x * size.width
            let cy = firefly.normalised.y * size.height

            // Outer glow — warm amber-yellow halo, like a real Photinus pyralis flash.
            let outerR: CGFloat = 22
            let outerGlow = Gradient(stops: [
                .init(color: Color(red: 1.00, green: 0.90, blue: 0.18, opacity: 0.55 * bright), location: 0.0),
                .init(color: Color(red: 0.90, green: 0.76, blue: 0.10, opacity: 0.20 * bright), location: 0.5),
                .init(color: .clear, location: 1.0),
            ])
            ctx.fill(
                Path(ellipseIn: CGRect(x: cx - outerR, y: cy - outerR,
                                       width: outerR * 2, height: outerR * 2)),
                with: .radialGradient(outerGlow,
                                      center: CGPoint(x: cx, y: cy),
                                      startRadius: 0,
                                      endRadius: outerR)
            )

            // Inner bright core — almost white-yellow at peak intensity.
            let innerR: CGFloat = 5
            let innerGlow = Gradient(stops: [
                .init(color: Color(red: 1.00, green: 0.97, blue: 0.65, opacity: 0.95 * bright), location: 0.0),
                .init(color: Color(red: 1.00, green: 0.88, blue: 0.30, opacity: 0.55 * bright), location: 0.5),
                .init(color: .clear, location: 1.0),
            ])
            ctx.fill(
                Path(ellipseIn: CGRect(x: cx - innerR, y: cy - innerR,
                                       width: innerR * 2, height: innerR * 2)),
                with: .radialGradient(innerGlow,
                                      center: CGPoint(x: cx, y: cy),
                                      startRadius: 0,
                                      endRadius: innerR)
            )
        }
    }
}

#Preview {
    NightAmbientView(timeOfDay: 21.5)
        .background(.black)
}
