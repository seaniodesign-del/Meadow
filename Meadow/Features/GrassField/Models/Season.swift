import SwiftUI

enum Season: String, CaseIterable, Codable {
    case spring, summer, fall, winter

    var next: Season {
        let all = Season.allCases
        let index = all.firstIndex(of: self)!
        return all[(index + 1) % all.count]
    }

    /// SF Symbol name (outline / monochrome variant) for use in SwiftUI controls.
    var sfSymbol: String {
        switch self {
        case .spring: return "leaf"
        case .summer: return "sun.max"
        case .fall:   return "wind"
        case .winter: return "snowflake"
        }
    }

    var icon: String {
        switch self {
        case .spring: return "🌱"
        case .summer: return "☀️"
        case .fall:   return "🍂"
        case .winter: return "❄️"
        }
    }

    var label: String { rawValue.capitalized }

    var palette: SeasonPalette {
        switch self {
        case .summer: return SeasonPalette(
            baseColour:   Color(hex: "#0D3F23"),
            midColour:    Color(hex: "#19562A"),
            tipColour:    Color(hex: "#598F27"),
            groundColour: Color(hex: "#0E2105"),  // must match MetalView clearColor
            shadowOpacity: 0.72
        )
        case .spring: return SeasonPalette(
            baseColour:   Color(hex: "#0e3010"),
            midColour:    Color(hex: "#1e5018"),
            tipColour:    Color(hex: "#5aaa20"),
            groundColour: Color(hex: "#050f02"),
            shadowOpacity: 0.62
        )
        case .fall: return SeasonPalette(
            baseColour:   Color(hex: "#1c2a08"),
            midColour:    Color(hex: "#425e12"),
            tipColour:    Color(hex: "#8aa020"),
            groundColour: Color(hex: "#0a0c03"),
            sunColour:    Color(hex: "#ccc420"),
            shadowOpacity: 0.68
        )
        case .winter: return SeasonPalette(
            // Dormant / sun-bleached dry grass. Same base→mid→tip gradient logic
            // as the green seasons; only the hues shift to a warm tan range so
            // the field reads as dormant cool-season grass in deep winter.
            baseColour:   Color(hex: "#3a2618"),  // shadowed root — dark warm brown
            midColour:    Color(hex: "#8a6840"),  // main blade body — warm khaki
            tipColour:    Color(hex: "#c8b07e"),  // sun-bleached tip — light wheat/cream
            groundColour: Color(hex: "#180f06"),  // dark soil glimpsed between sparse blades
            sunColour:    Color(hex: "#d8a868"),  // warm golden tint for sunlight streaks
            shadowOpacity: 0.48                    // softer shadows — dry grass scatters more
        )
        }
    }
}

struct SeasonPalette {
    let baseColour: Color
    let midColour: Color
    let tipColour: Color
    let groundColour: Color
    /// Tint colour applied additively to sunlight streaks.
    let sunColour: Color
    let shadowOpacity: Double

    init(baseColour: Color, midColour: Color, tipColour: Color,
         groundColour: Color, sunColour: Color = Color(hex: "#8CB820"),
         shadowOpacity: Double) {
        self.baseColour   = baseColour
        self.midColour    = midColour
        self.tipColour    = tipColour
        self.groundColour = groundColour
        self.sunColour    = sunColour
        self.shadowOpacity = shadowOpacity
    }
}

// MARK: - Hex colour convenience
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        let val = UInt64(hex, radix: 16) ?? 0
        let r = Double((val >> 16) & 0xFF) / 255
        let g = Double((val >> 8)  & 0xFF) / 255
        let b = Double(val         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
