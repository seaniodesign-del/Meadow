import SwiftUI

struct SettingsButton: View {
    @Binding var showSettings: Bool

    var body: some View {
        Button("Settings", systemImage: "gear") {
            showSettings = true
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 22, weight: .regular))
        .foregroundStyle(.white)
        .frame(width: 56, height: 56)
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .circle)
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.7), trigger: showSettings)
    }
}
