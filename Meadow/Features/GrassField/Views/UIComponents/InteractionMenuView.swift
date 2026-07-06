import SwiftUI

/// Bottom interaction menu — three glass cards (Ripple / Foot step / Star).
///
/// Tapping a card selects that interaction; tapping the selected card again
/// returns to `.none` (default grass-parting). Matches the Figma layout:
/// 24 pt side margins, 16 pt gaps, 108 pt tall cards, icon top-left, label
/// bottom-left.
struct InteractionMenuView: View {
    @Binding var selection: GrassInteraction

    var body: some View {
        HStack(spacing: 16) {
            ForEach(GrassInteraction.selectableCases) { mode in
                InteractionCard(
                    mode: mode,
                    isSelected: selection == mode
                ) {
                    selection = (selection == mode) ? .none : mode
                }
            }
        }
        .padding(.horizontal, 24)
    }
}

/// A single selectable interaction card.
private struct InteractionCard: View {
    let mode: GrassInteraction
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 22, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                Spacer(minLength: 8)
                Text(mode.label)
                    .font(.system(size: 16, weight: .medium))
            }
            .foregroundStyle(.white.opacity(isSelected ? 1.0 : 0.82))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 108)
            .padding(17)
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSelected ? .clear.tint(.white.opacity(0.16)).interactive()
                       : .clear.interactive(),
            in: .rect(cornerRadius: 18)
        )
        .overlay {
            // 3 pt solid white ring on the active card. `strokeBorder` keeps the
            // full 3 pt inside the card bounds (a centred stroke would be clipped
            // to ~1.5 pt by the rounded-rect edge).
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.white, lineWidth: 3)
                .opacity(isSelected ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.2), value: isSelected)
        .sensoryFeedback(.selection, trigger: isSelected)
    }
}

#Preview {
    @Previewable @State var selection: GrassInteraction = .ripple
    ZStack {
        Color(red: 0.05, green: 0.12, blue: 0.03).ignoresSafeArea()
        VStack {
            Spacer()
            InteractionMenuView(selection: $selection)
                .padding(.bottom, 24)
        }
    }
}
