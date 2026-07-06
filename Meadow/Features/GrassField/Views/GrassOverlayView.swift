import SwiftUI

/// The UI overlay sitting above the Metal grass canvas.
///
/// Top row     — settings (left) and season (right) controls.
/// Bottom row  — the interaction menu (Ripple / Foot step / Star).
///
/// Controls live at the top so the interaction menu owns the bottom edge,
/// matching the Figma layout.
struct GrassOverlayView: View {
    @Bindable var viewModel: GrassFieldViewModel

    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Top controls ──────────────────────────────────────────────
            HStack(alignment: .top) {
                SettingsButton(showSettings: $showSettings)
                Spacer()
                seasonButton
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            Spacer()

            // ── Interaction menu ──────────────────────────────────────────
            InteractionMenuView(selection: $viewModel.activeInteraction)
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(settings: viewModel.settings) {
                Task { await viewModel.regenerateField() }
            }
        }
    }

    private var seasonButton: some View {
        SeasonButton(season: viewModel.settings.currentSeason) { season in
            viewModel.settings.currentSeason = season
        }
    }
}
