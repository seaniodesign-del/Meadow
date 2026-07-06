import SwiftUI

/// Maps a 24-hour clock value (0.0–24.0) to a `SeasonPalette`.
///
/// Keyframes are hand-tuned against real-world lighting references.
/// Values between keyframes are linearly interpolated in sRGB space.
/// The active palette drives both the grass fragment shader and the
/// Metal view's clear colour so the ground always matches the sky mood.
///
/// Each `Season` has its own keyframe table. `summer` / `spring` / `fall`
/// currently share the canonical green table; `winter` uses a warm
/// tan / wheat table that reads as dormant, sun-bleached cool-season grass.
struct TimeOfDay {

    // MARK: - Public API

    static func palette(for hour: Double, season: Season = .summer) -> SeasonPalette {
        interpolate(in: keyframes(for: season), at: hour)
    }

    /// Human-readable label for the given hour value (e.g. "7:30 AM").
    static func label(for hour: Double) -> String {
        let h = Int(hour) % 24
        let m = Int(hour.truncatingRemainder(dividingBy: 1) * 60)
        let period = h < 12 ? "AM" : "PM"
        let display = h == 0 ? 12 : (h > 12 ? h - 12 : h)
        return String(format: "%d:%02d %@", display, m, period)
    }

    // MARK: - Keyframe lookup

    private static func keyframes(for season: Season) -> [Keyframe] {
        switch season {
        case .winter:                   return winterKeyframes
        case .summer, .spring, .fall:   return greenKeyframes
        }
    }

    private static func interpolate(in kf: [Keyframe], at hour: Double) -> SeasonPalette {
        let t = ((hour.truncatingRemainder(dividingBy: 24)) + 24)
                    .truncatingRemainder(dividingBy: 24)
        for i in 0..<(kf.count - 1) where t >= kf[i].hour && t < kf[i + 1].hour {
            let progress = (t - kf[i].hour) / (kf[i + 1].hour - kf[i].hour)
            return lerp(kf[i].palette, kf[i + 1].palette, t: progress)
        }
        return kf.last!.palette
    }

    // MARK: - Keyframe type

    private struct Keyframe {
        let hour: Double
        let palette: SeasonPalette
    }

    // MARK: - Green keyframes  (summer / spring / fall)
    //
    // The original canonical day cycle: night → dawn → noon green → sunset →
    // dusk. Used for all three "green" seasons until each gets its own pass.

    private static let greenKeyframes: [Keyframe] = [
        Keyframe(hour:  0, palette: SeasonPalette(
            baseColour:   Color(hex: "#060d0a"),
            midColour:    Color(hex: "#0c1a18"),
            tipColour:    Color(hex: "#1a3228"),
            groundColour: Color(hex: "#020605"),
            sunColour:    Color(hex: "#152818"),
            shadowOpacity: 0.12
        )),
        Keyframe(hour:  5, palette: SeasonPalette(
            baseColour:   Color(hex: "#080e0c"),
            midColour:    Color(hex: "#121e24"),
            tipColour:    Color(hex: "#203832"),
            groundColour: Color(hex: "#040608"),
            sunColour:    Color(hex: "#18281e"),
            shadowOpacity: 0.18
        )),
        Keyframe(hour:  6.5, palette: SeasonPalette(
            baseColour:   Color(hex: "#1a1000"),
            midColour:    Color(hex: "#4a2a00"),
            tipColour:    Color(hex: "#cc6e10"),
            groundColour: Color(hex: "#080400"),
            sunColour:    Color(hex: "#ff8c20"),
            shadowOpacity: 0.45
        )),
        Keyframe(hour:  9, palette: SeasonPalette(
            baseColour:   Color(hex: "#0d2e10"),
            midColour:    Color(hex: "#1a4a18"),
            tipColour:    Color(hex: "#4a8820"),
            groundColour: Color(hex: "#040e06"),
            sunColour:    Color(hex: "#78b828"),
            shadowOpacity: 0.60
        )),
        Keyframe(hour: 12, palette: SeasonPalette(
            baseColour:   Color(hex: "#0D3F23"),
            midColour:    Color(hex: "#19562A"),
            tipColour:    Color(hex: "#598F27"),
            groundColour: Color(hex: "#040d02"),
            sunColour:    Color(hex: "#8CB820"),
            shadowOpacity: 0.72
        )),
        Keyframe(hour: 17, palette: SeasonPalette(
            baseColour:   Color(hex: "#1a1400"),
            midColour:    Color(hex: "#4e6618"),
            tipColour:    Color(hex: "#c88800"),
            groundColour: Color(hex: "#080500"),
            sunColour:    Color(hex: "#E09820"),
            shadowOpacity: 0.62
        )),
        Keyframe(hour: 19, palette: SeasonPalette(
            baseColour:   Color(hex: "#1C0E00"),
            midColour:    Color(hex: "#637E20"),
            tipColour:    Color(hex: "#DE9E05"),
            groundColour: Color(hex: "#0A0600"),
            sunColour:    Color(hex: "#FFB030"),
            shadowOpacity: 0.50
        )),
        Keyframe(hour: 21, palette: SeasonPalette(
            baseColour:   Color(hex: "#080d0c"),
            midColour:    Color(hex: "#121e1c"),
            tipColour:    Color(hex: "#22342e"),
            groundColour: Color(hex: "#030605"),
            sunColour:    Color(hex: "#15261c"),
            shadowOpacity: 0.15
        )),
        Keyframe(hour: 24, palette: SeasonPalette(
            baseColour:   Color(hex: "#060d0a"),
            midColour:    Color(hex: "#0c1a18"),
            tipColour:    Color(hex: "#1a3228"),
            groundColour: Color(hex: "#020605"),
            sunColour:    Color(hex: "#152818"),
            shadowOpacity: 0.12
        )),
    ]

    // MARK: - Winter keyframes  (dormant dry grass)
    //
    // Day cycle for sun-bleached dormant cool-season grass: warm browns at
    // night, dramatic golden sunrise/sunset, and a peak midday palette of
    // wheat / khaki / dark-warm-brown sampled from the reference photo.
    // Shadow opacity stays a touch softer than the green table because dry
    // grass scatters more light back into the shadows than living blades.

    private static let winterKeyframes: [Keyframe] = [
        // Midnight — very dark warm browns
        Keyframe(hour:  0, palette: SeasonPalette(
            baseColour:   Color(hex: "#0a0805"),
            midColour:    Color(hex: "#181210"),
            tipColour:    Color(hex: "#2c2418"),
            groundColour: Color(hex: "#050300"),
            sunColour:    Color(hex: "#1a1410"),
            shadowOpacity: 0.10
        )),
        // Pre-dawn — still dark, a hint of amber
        Keyframe(hour:  5, palette: SeasonPalette(
            baseColour:   Color(hex: "#0c0a06"),
            midColour:    Color(hex: "#1c1814"),
            tipColour:    Color(hex: "#322820"),
            groundColour: Color(hex: "#060402"),
            sunColour:    Color(hex: "#1c1612"),
            shadowOpacity: 0.16
        )),
        // Sunrise — warm orange tips like sunlit straw
        Keyframe(hour:  6.5, palette: SeasonPalette(
            baseColour:   Color(hex: "#1a0c00"),
            midColour:    Color(hex: "#482a00"),
            tipColour:    Color(hex: "#d28030"),
            groundColour: Color(hex: "#080300"),
            sunColour:    Color(hex: "#ff9028"),
            shadowOpacity: 0.42
        )),
        // Mid-morning — warming into khaki
        Keyframe(hour:  9, palette: SeasonPalette(
            baseColour:   Color(hex: "#2a1810"),
            midColour:    Color(hex: "#6a5028"),
            tipColour:    Color(hex: "#a89060"),
            groundColour: Color(hex: "#100805"),
            sunColour:    Color(hex: "#d09838"),
            shadowOpacity: 0.50
        )),
        // Midday — peak dry-grass palette (sampled from reference)
        Keyframe(hour: 12, palette: SeasonPalette(
            baseColour:   Color(hex: "#3a2618"),
            midColour:    Color(hex: "#8a6840"),
            tipColour:    Color(hex: "#c8b07e"),
            groundColour: Color(hex: "#180f06"),
            sunColour:    Color(hex: "#d8a868"),
            shadowOpacity: 0.48
        )),
        // Late afternoon — warmer, golden cast
        Keyframe(hour: 17, palette: SeasonPalette(
            baseColour:   Color(hex: "#2a1400"),
            midColour:    Color(hex: "#806020"),
            tipColour:    Color(hex: "#d8a040"),
            groundColour: Color(hex: "#0c0500"),
            sunColour:    Color(hex: "#e89828"),
            shadowOpacity: 0.52
        )),
        // Golden hour / sunset — dramatic
        Keyframe(hour: 19, palette: SeasonPalette(
            baseColour:   Color(hex: "#1c0e00"),
            midColour:    Color(hex: "#735525"),
            tipColour:    Color(hex: "#e0a830"),
            groundColour: Color(hex: "#0a0500"),
            sunColour:    Color(hex: "#ffb030"),
            shadowOpacity: 0.48
        )),
        // Dusk — warm fading
        Keyframe(hour: 21, palette: SeasonPalette(
            baseColour:   Color(hex: "#100805"),
            midColour:    Color(hex: "#221814"),
            tipColour:    Color(hex: "#3a2820"),
            groundColour: Color(hex: "#060403"),
            sunColour:    Color(hex: "#1c1410"),
            shadowOpacity: 0.14
        )),
        // Night — closes the loop back to midnight
        Keyframe(hour: 24, palette: SeasonPalette(
            baseColour:   Color(hex: "#0a0805"),
            midColour:    Color(hex: "#181210"),
            tipColour:    Color(hex: "#2c2418"),
            groundColour: Color(hex: "#050300"),
            sunColour:    Color(hex: "#1a1410"),
            shadowOpacity: 0.10
        )),
    ]

    // MARK: - Interpolation

    private static func lerp(_ a: SeasonPalette, _ b: SeasonPalette, t: Double) -> SeasonPalette {
        SeasonPalette(
            baseColour:    lerpColour(a.baseColour,    b.baseColour,    t: t),
            midColour:     lerpColour(a.midColour,     b.midColour,     t: t),
            tipColour:     lerpColour(a.tipColour,     b.tipColour,     t: t),
            groundColour:  lerpColour(a.groundColour,  b.groundColour,  t: t),
            sunColour:     lerpColour(a.sunColour,     b.sunColour,     t: t),
            shadowOpacity: a.shadowOpacity + (b.shadowOpacity - a.shadowOpacity) * t
        )
    }

    private static func lerpColour(_ a: Color, _ b: Color, t: Double) -> Color {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        UIColor(a).getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        UIColor(b).getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let f = CGFloat(t)
        return Color(
            red:   Double(ar + (br - ar) * f),
            green: Double(ag + (bg - ag) * f),
            blue:  Double(ab + (bb - ab) * f)
        )
    }
}
