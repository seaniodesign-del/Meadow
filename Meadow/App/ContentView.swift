import SwiftUI

struct ContentView: View {
    @State private var viewModel = GrassFieldViewModel()

    /// Drives the onboarding overlay in the view hierarchy.
    ///
    /// Initialised to `true` so the dial is shown on every cold launch.
    /// `@State` (not `@AppStorage`) — we deliberately do NOT persist this:
    /// users get to re-pick a season each time they open the app.
    /// On a foreground-from-background switch the View instance is preserved,
    /// so the flag keeps its current value (no surprise re-appearance).
    @State private var showOnboarding: Bool = {
        #if DEBUG
        // Test hook: `defaults write …meadow debugSkipOnboarding -bool YES`
        // jumps straight to the main HUD. Never consulted in release builds.
        return !UserDefaults.standard.bool(forKey: "debugSkipOnboarding")
        #else
        return true
        #endif
    }()

    var body: some View {
        ZStack {
            // MARK: - Metal grass canvas (always rendering, season-reactive)
            MetalView(viewModel: viewModel)
                .ignoresSafeArea()

            // MARK: - Night ambient effects (street lamp + fireflies)
            NightAmbientView(timeOfDay: viewModel.settings.timeOfDay)

            // MARK: - Main UI overlay (hidden while onboarding is active)
            if !showOnboarding {
                GrassOverlayView(viewModel: viewModel)
                    .transition(.opacity)
                    .zIndex(1)
            }

            // MARK: - Cold-launch season-selection overlay
            if showOnboarding {
                OnboardingView(settings: viewModel.settings) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showOnboarding = false
                    }
                }
                .zIndex(2)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            GrassAudioEngine.shared.start(enabled: viewModel.settings.soundEnabled)
        }
        .onChange(of: viewModel.settings.soundEnabled) { _, enabled in
            GrassAudioEngine.shared.setEnabled(enabled)
        }
    }
}

#Preview {
    ContentView()
}
