import SwiftUI

/// The set of grass interaction modes selectable from the interaction menu.
///
/// `.none` is the default — touches part the grass as usual. Selecting a mode
/// makes touches spawn the corresponding visual effect in the field instead.
enum GrassInteraction: String, CaseIterable, Identifiable, Hashable {
    case none
    case ripple
    case footstep
    case star

    var id: String { rawValue }

    /// The three modes exposed as cards in the interaction menu (excludes `.none`).
    static let selectableCases: [GrassInteraction] = [.ripple, .footstep, .star]

    /// Display label shown beneath the icon.
    var label: String {
        switch self {
        case .none:     return ""
        case .ripple:   return "Ripple"
        case .footstep: return "Foot step"
        case .star:     return "Star"
        }
    }

    /// SF Symbol approximating the Figma's Lucide icon for each mode.
    var symbol: String {
        switch self {
        case .none:     return "hand.tap"
        case .ripple:   return "drop"
        case .footstep: return "shoeprints.fill"
        case .star:     return "star"
        }
    }
}
