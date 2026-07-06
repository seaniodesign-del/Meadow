import Foundation

/// Persisted user settings. Stored in UserDefaults.
@Observable
@MainActor
final class GrassSettings {
    // MARK: - Stored properties (backed by UserDefaults)

    var windSpeed: WindSpeed {
        didSet { UserDefaults.standard.set(windSpeed.rawValue, forKey: Keys.windSpeed) }
    }
    var density: GrassDensity {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: Keys.density) }
    }
    var bladeHeight: BladeHeight {
        didSet { UserDefaults.standard.set(bladeHeight.rawValue, forKey: Keys.bladeHeight) }
    }
    var hapticsEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: Keys.haptics) }
    }
    var soundEnabled: Bool {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: Keys.sound) }
    }
    var currentSeason: Season {
        didSet { UserDefaults.standard.set(currentSeason.rawValue, forKey: Keys.season) }
    }
    /// Hour of day in [0, 24). Always driven by the device clock — not persisted.
    var timeOfDay: Double

    /// Hours to add to real local time. Zero = tracking the live clock exactly.
    /// Set when the user drags the time slider; cleared by the "Live" button.
    /// Not persisted — always starts at zero (live) on launch.
    var manualTimeOffset: Double = 0

    /// True while the display time exactly tracks the device clock.
    var isLiveTime: Bool { abs(manualTimeOffset) < 0.0001 }

    // MARK: - Init
    init() {
        let d = UserDefaults.standard
        windSpeed     = WindSpeed(rawValue: d.string(forKey: Keys.windSpeed) ?? "") ?? .gentle
        density       = GrassDensity(rawValue: d.string(forKey: Keys.density) ?? "") ?? .normal
        bladeHeight   = BladeHeight(rawValue: d.string(forKey: Keys.bladeHeight) ?? "") ?? .medium
        hapticsEnabled = d.object(forKey: Keys.haptics) as? Bool ?? true
        soundEnabled   = d.object(forKey: Keys.sound) as? Bool ?? true
        currentSeason  = Season(rawValue: d.string(forKey: Keys.season) ?? "") ?? .summer
        // Initialise to the real local time so the first frame is correct
        // before `syncTimeOfDay` fires at the end of the first second.
        let comps  = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        timeOfDay  = Double(comps.hour  ?? 12)
                   + Double(comps.minute ?? 0) / 60.0
                   + Double(comps.second ?? 0) / 3600.0
    }

    // MARK: - Enums
    enum WindSpeed: String, CaseIterable {
        case off, gentle, breezy
        var amplitudeMultiplier: Float {
            switch self { case .off: 0; case .gentle: 1.0; case .breezy: 1.8 }
        }
    }

    enum GrassDensity: String, CaseIterable {
        case sparse, normal, dense
        var bladeCount: Int {
            switch self { case .sparse: 4000; case .normal: 7000; case .dense: 10000 }
        }
    }

    enum BladeHeight: String, CaseIterable {
        case short, medium, tall
        var heightMultiplier: Float {
            switch self { case .short: 0.7; case .medium: 1.0; case .tall: 1.4 }
        }
    }

    // MARK: - Keys
    private enum Keys {
        static let windSpeed  = "windSpeed"
        static let density    = "density"
        static let bladeHeight = "bladeHeight"
        static let haptics    = "hapticsEnabled"
        static let sound      = "soundEnabled"
        static let season     = "currentSeason"
        static let timeOfDay  = "timeOfDay"
    }
}
