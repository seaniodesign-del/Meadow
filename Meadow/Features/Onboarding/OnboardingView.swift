import SwiftUI

/// Full-screen season-selection overlay shown on first app launch.
///
/// The live grass field renders behind this view the whole time — the user
/// sees the field react to whichever season they spin to before tapping Start.
///
/// Layout uses explicit `.position()` against the GeometryReader's size so
/// modifier-order issues (padding vs. frame) can't break positioning.
struct OnboardingView: View {

    @Bindable var settings: GrassSettings
    let onStart: () -> Void

    /// How many points of the 629 pt dial sit above the screen edge.
    private let dialVisible: CGFloat = 270

    /// Angular drift fed back from the dial (used to blur the season name).
    @State private var drift: Double = 0

    /// Exit animation flag.
    @State private var isExiting = false

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let safeTop = geo.safeAreaInsets.top
            let safeBottom = geo.safeAreaInsets.bottom

            ZStack {
                // ── Header (top-left) ─────────────────────────────────────────
                header
                    .frame(width: w - 64, alignment: .leading)
                    .position(
                        x: 32 + (w - 64) / 2,
                        y: max(safeTop, 40) + 56 + 40
                    )

                // ── Season name (just above the dial) ─────────────────────────
                seasonName
                    .position(
                        x: w / 2,
                        y: h - dialVisible - 36
                    )

                // ── Liquid-glass rotary dial (peeks from bottom) ──────────────
                SeasonDialView(
                    selectedSeason: $settings.currentSeason,
                    onSnapped: {},
                    drift: $drift
                )
                .frame(width: SeasonDialView.diameter, height: SeasonDialView.diameter)
                .position(
                    x: w / 2,
                    // Centre of dial = screen_bottom + (radius - visible)
                    // → top of dial sits exactly `dialVisible` pts above the bottom
                    y: h + (SeasonDialView.diameter / 2) - dialVisible
                )

                // ── Start button ──────────────────────────────────────────────
                startButton
                    .position(
                        x: w / 2,
                        y: h - max(safeBottom, 16) - 16 - 28
                    )
            }
        }
        .ignoresSafeArea()
        // ── Exit animation ───────────────────────────────────────────────────
        .opacity(isExiting ? 0 : 1)
        .blur(radius: isExiting ? 18 : 0)
        .scaleEffect(isExiting ? 1.04 : 1.0)
        .animation(.easeIn(duration: 0.42), value: isExiting)
        // ── Confirming haptic when a new season is committed ──────────────────
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.65),
                         trigger: settings.currentSeason)
    }

    // MARK: - Sub-views

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Welcome back")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .tracking(-0.8)

            Text("Meadow")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var seasonName: some View {
        Text(settings.currentSeason.label)
            .font(.system(.title, design: .rounded, weight: .semibold))
            .foregroundStyle(.white)
            .blur(radius: min(drift * 0.18, 8))
            .opacity(max(0.45, 1.0 - drift * 0.022))
            .id(settings.currentSeason)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .animation(.spring(response: 0.25, dampingFraction: 0.8),
                       value: settings.currentSeason)
    }

    private var startButton: some View {
        Button {
            handleStart()
        } label: {
            Text("Start")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 338, height: 56)
                .background(.white, in: .capsule)
        }
    }

    // MARK: - Actions

    private func handleStart() {
        Task {
            withAnimation(.easeIn(duration: 0.42)) { isExiting = true }
            try? await Task.sleep(for: .seconds(0.42))
            onStart()
        }
    }
}

// MARK: - Preview

#Preview("Onboarding") {
    @Previewable @State var settings = GrassSettings()
    ZStack {
        Color(hex: "#0a0c03").ignoresSafeArea()
        OnboardingView(settings: settings, onStart: {})
    }
}
