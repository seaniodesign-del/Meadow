import SwiftUI

struct SettingsSheet: View {
    @Bindable var settings: GrassSettings
    let onDensityChanged: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                // ── Lighting (Time of Day) — first so it's visible at the
                //    compact detent without scrolling. ─────────────────────
                Section {
                    LabeledContent {
                        Text(TimeOfDay.label(for: settings.timeOfDay))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.spring(response: 0.25, dampingFraction: 0.6),
                                       value: settings.timeOfDay)
                    } label: {
                        Text("Time of Day")
                    }
                    Slider(
                        value: Binding(
                            get: { settings.timeOfDay },
                            set: { newValue in
                                settings.timeOfDay = newValue
                                // Keep manualTimeOffset in sync on every tick so
                                // syncTimeOfDay never overwrites the user's chosen time.
                                let comps = Calendar.current.dateComponents(
                                    [.hour, .minute, .second], from: Date())
                                let real = Double(comps.hour  ?? 12)
                                         + Double(comps.minute ?? 0) / 60.0
                                         + Double(comps.second ?? 0) / 3600.0
                                var offset = newValue - real
                                // Normalise to [-12, 12] — always picks the shortest path.
                                if offset >  12 { offset -= 24 }
                                if offset < -12 { offset += 24 }
                                settings.manualTimeOffset = offset
                            }
                        ),
                        in: 0...24,
                        step: 0.25
                    )
                    .tint(.orange)
                } header: {
                    Text("Lighting")
                }

                // ── Wind ─────────────────────────────────────────────────
                Section("Wind") {
                    Picker("Wind Speed", selection: $settings.windSpeed) {
                        ForEach(GrassSettings.WindSpeed.allCases, id: \.self) { speed in
                            Text(speed.rawValue.capitalized).tag(speed)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // ── Grass ─────────────────────────────────────────────────
                Section("Grass") {
                    LabeledContent("Density") {
                        Picker("Density", selection: $settings.density) {
                            ForEach(GrassSettings.GrassDensity.allCases, id: \.self) { d in
                                Text(d.rawValue.capitalized).tag(d)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .onChange(of: settings.density) { onDensityChanged() }

                    LabeledContent("Blade Height") {
                        Picker("Blade Height", selection: $settings.bladeHeight) {
                            ForEach(GrassSettings.BladeHeight.allCases, id: \.self) { h in
                                Text(h.rawValue.capitalized).tag(h)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .onChange(of: settings.bladeHeight) { onDensityChanged() }
                }

                // ── Feel ──────────────────────────────────────────────────
                Section("Feel") {
                    Toggle("Haptics", isOn: $settings.hapticsEnabled)
                    Toggle("Sound", isOn: $settings.soundEnabled)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !settings.isLiveTime {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Live", systemImage: "clock.arrow.circlepath") {
                            settings.manualTimeOffset = 0
                        }
                        .tint(.orange)
                    }
                }
            }
        }
        // Compact detent sized to show exactly the Lighting section
        // (drag indicator 16 + nav bar 50 + section header 28 + label row 44 + slider row 44 + padding)
        .presentationDetents([.height(220), .medium, .large])
        .presentationDragIndicator(.visible)
    }
}
