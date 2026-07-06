import AVFoundation
import os.log

/// Manages background audio for the meadow scene.
///
/// Two tracks run simultaneously with cross-faded volumes driven by `timeOfDay`:
///   • Day  — `background_music.mp3`  (full volume before 20:15, fading out by 20:45)
///   • Night — `night_music.mp3`       (fades in starting 20:15, full by 20:45)
///
/// `updateVolumes(for:)` must be called whenever `timeOfDay` changes (every render
/// frame) so the crossfade tracks the slider in real time.
///
/// Setup strategy:
///   • AVAudioSession (setCategory/setActive) stays on @MainActor — the iOS
///     simulator's RPAC framework crashes if this is called off the main thread.
///   • AVAudioPlayer(contentsOf:) + prepareToPlay() for large files runs on a
///     background Task to avoid blocking app startup.
@MainActor
final class GrassAudioEngine {
    static let shared = GrassAudioEngine()

    private let log = Logger(subsystem: "com.meadow.app", category: "GrassAudioEngine")

    private var dayPlayer:   AVAudioPlayer?
    private var nightPlayer: AVAudioPlayer?

    /// Whether `start(enabled:)` has been called.
    private var isStarted = false
    /// Deferred-start flags set when start() is called before players are ready.
    private var dayPlayWhenReady   = false
    private var nightPlayWhenReady = false

    /// Last timeOfDay seen — used to avoid redundant volume updates.
    private var lastTimeOfDay: Double = -1

    // MARK: - Init

    private init() {
        observeInterruptions()
        Task { await setup() }
    }

    // MARK: - Async setup

    private func setup() async {
        // iOS Simulator has no audio hardware and AVAudioSession can assert
        // under some builds — skip everything on the simulator.
        #if targetEnvironment(simulator)
        log.info("Audio disabled on simulator — skipping setup")
        return
        #else
        // Step 1: Configure audio session on main actor (AVAudioSession is not
        // thread-safe; must stay here before the background file loads).
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            log.error("AVAudioSession setup failed: \(error)")
            return
        }

        guard
            let dayURL   = Bundle.main.url(forResource: "background_music", withExtension: "mp3"),
            let nightURL = Bundle.main.url(forResource: "night_music",       withExtension: "mp3")
        else {
            log.error("One or more audio files not found in bundle")
            return
        }

        // Step 2: Load both players on a background thread — prepareToPlay()
        // for large files takes several seconds and must not block the UI.
        struct Players: @unchecked Sendable {
            let day: AVAudioPlayer
            let night: AVAudioPlayer
        }

        let result: Players? = await Task.detached(priority: .background) {
            guard
                let day   = try? AVAudioPlayer(contentsOf: dayURL),
                let night = try? AVAudioPlayer(contentsOf: nightURL)
            else { return nil }
            day.numberOfLoops   = -1
            day.volume          = 0.55
            day.prepareToPlay()
            night.numberOfLoops = -1
            night.volume        = 0.0   // starts silent; fades in via updateVolumes
            night.prepareToPlay()
            return Players(day: day, night: night)
        }.value

        guard let result else {
            log.error("AVAudioPlayer init failed for one or both tracks")
            return
        }

        dayPlayer   = result.day
        nightPlayer = result.night
        log.info("Audio ready — day: \(result.day.duration, format: .fixed(precision: 1))s  night: \(result.night.duration, format: .fixed(precision: 1))s")

        // Honour deferred-start requests.
        if dayPlayWhenReady {
            dayPlayWhenReady = false
            dayPlayer?.play()
            isStarted = true
            log.info("Day music started (deferred)")
        }
        if nightPlayWhenReady {
            nightPlayWhenReady = false
            nightPlayer?.play()
            log.info("Night music started (deferred, silent until crossfade)")
        }
        #endif
    }

    // MARK: - Public API

    /// Call once on app launch to begin playback (if sound is enabled).
    func start(enabled: Bool) {
        guard enabled else { return }

        if let day = dayPlayer {
            if !day.isPlaying { day.play() }
        } else {
            dayPlayWhenReady = true
        }

        // Night track always starts playing silently from launch so it's
        // pre-buffered and ready to crossfade in smoothly at 8:15 PM.
        if let night = nightPlayer {
            if !night.isPlaying { night.play() }
        } else {
            nightPlayWhenReady = true
        }

        isStarted = true
        log.info("Audio engine started")
    }

    func stop() {
        dayPlayWhenReady   = false
        nightPlayWhenReady = false
        dayPlayer?.stop()
        nightPlayer?.stop()
        isStarted = false
    }

    func setEnabled(_ enabled: Bool) {
        if enabled { start(enabled: true) } else { stop() }
    }

    /// Drive the crossfade. Call every frame (or whenever timeOfDay changes).
    /// Day track is full volume before 20.15; night track fades in 20.15→20.75;
    /// both settle to steady-state volumes after 20.75.
    func updateVolumes(for timeOfDay: Double) {
        guard isStarted else { return }
        guard timeOfDay != lastTimeOfDay else { return }
        lastTimeOfDay = timeOfDay

        // crossFade ∈ [0, 1] — 0 = full day, 1 = full night
        let crossFade: Double
        let fadeStart = 20.25   // 8:15 PM
        let fadeEnd   = 20.75   // 8:45 PM
        if timeOfDay < fadeStart {
            crossFade = 0.0
        } else if timeOfDay > fadeEnd {
            crossFade = 1.0
        } else {
            crossFade = (timeOfDay - fadeStart) / (fadeEnd - fadeStart)
        }

        // Smooth step for a more natural-sounding fade curve.
        let t = crossFade * crossFade * (3 - 2 * crossFade)

        let dayVol   = Float((1.0 - t) * 0.55)
        let nightVol = Float(t * 0.60)

        dayPlayer?.volume   = dayVol
        nightPlayer?.volume = nightVol
    }

    // MARK: - Interruption handling

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let info        = notification.userInfo
            let typeValue   = info?[AVAudioSessionInterruptionTypeKey]   as? UInt
            let optionValue = info?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in
                self?.handleInterruption(typeValue: typeValue, optionValue: optionValue)
            }
        }
    }

    private func handleInterruption(typeValue: UInt?, optionValue: UInt?) {
        guard
            let typeValue,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            dayPlayer?.pause()
            nightPlayer?.pause()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionValue ?? 0)
            if options.contains(.shouldResume), isStarted {
                try? AVAudioSession.sharedInstance().setActive(true)
                dayPlayer?.play()
                nightPlayer?.play()
            }
        @unknown default:
            break
        }
    }
}
