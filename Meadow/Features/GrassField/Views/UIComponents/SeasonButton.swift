import SwiftUI

struct SeasonButton: View {
    let season: Season
    let onSeasonSelected: (Season) -> Void

    @State private var selectionCount = 0

    var body: some View {
        Menu {
            // Inline Picker gives automatic checkmark on the selected row.
            Picker("Season", selection: Binding(
                get: { season },
                set: {
                    onSeasonSelected($0)
                    selectionCount += 1
                }
            )) {
                ForEach(Season.allCases, id: \.self) { s in
                    Label(s.label, systemImage: s.sfSymbol)
                        .tag(s)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: season.sfSymbol)
                    .font(.system(size: 18, weight: .regular))
                Text(season.label)
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .glassEffect(.clear.interactive(), in: .capsule)
        .sensoryFeedback(.selection, trigger: selectionCount)
    }
}

#Preview {
    ZStack {
        Color.black
        SeasonButton(season: .summer) { _ in }
    }
}
