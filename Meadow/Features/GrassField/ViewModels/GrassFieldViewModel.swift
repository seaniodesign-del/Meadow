import SwiftUI
import UIKit
import os.log

/// Central view model. Owns all grass blade state and orchestrates
/// physics, touch input, wind, and season transitions.
@Observable
@MainActor
final class GrassFieldViewModel {

    private let log = Logger(subsystem: "com.meadow.app", category: "GrassFieldViewModel")

    // MARK: - Public state
    var blades: [GrassBlade] = []
    /// Incremented every time the field is regenerated. The renderer watches
    /// this instead of blade count so rotation (same count, new positions) is detected.
    private(set) var fieldVersion: Int = 0
    var settings = GrassSettings()

    /// Currently selected grass interaction. `.none` = default grass parting.
    /// Observed by the interaction menu; changing it clears any residual effect.
    var activeInteraction: GrassInteraction = .none {
        didSet {
            guard oldValue != activeInteraction else { return }
            #if DEBUG
            log.info("TOUCHDBG activeInteraction \(oldValue.rawValue) → \(self.activeInteraction.rawValue)")
            #endif
            interactionSystem.reset()
            for i in touchBendAngles.indices { touchBendAngles[i] = 0 }
            interactionDirty = true   // force one clear-apply pass
            activeTouches.removeAll()
        }
    }

    /// Drives the three touch-spawned grass effects (Ripple / Foot step / Star).
    @ObservationIgnored let interactionSystem = GrassInteractionSystem()
    /// Set whenever effects are present so we run one final zeroing pass once
    /// they all expire, then idle without touching the bend array every frame.
    @ObservationIgnored private var interactionDirty = false

    /// Only `settings` is observed by SwiftUI views; the rest are renderer internals.
    @ObservationIgnored var activeTouches: [TouchPoint] = []
    var isGenerating = false
    @ObservationIgnored var screenSize: CGSize = CGSize(width: 393, height: 852)  // updated by renderer

    /// Per-blade touch bend angle (radians). Parallel to `blades`.
    /// Updated each frame by `updateTouchBends`; read by `GrassRenderer`
    /// to write directly into the Metal instance buffer.
    @ObservationIgnored private(set) var touchBendAngles: [Float] = []

    // MARK: - Seasonal systems (non-nil only for the relevant season)
    @ObservationIgnored private(set) var leafSystem:       LeafSystem?
    @ObservationIgnored private(set) var dandelionSystem:  DandelionSystem?

    // MARK: - Private
    @ObservationIgnored private var spatialGrid: SpatialGrid<GrassBlade>?
    /// Fast UUID → array-index lookup so touch updates stay O(k) per finger.
    @ObservationIgnored private var bladeIndexMap: [UUID: Int] = [:]
    @ObservationIgnored private var seasonTransition: SeasonTransitionState?

    /// The screen size that the current grass field was generated for.
    /// Used to detect orientation changes and trigger a re-generation.
    @ObservationIgnored private var lastGeneratedSize: CGSize = .zero

    /// Accumulates frame deltas so the clock sync runs once per second.
    @ObservationIgnored private var timeSyncAccumulator: Float = 0

    /// Cumulative elapsed time (seconds) since the view model was created.
    /// Used as a monotonic clock for per-blade trail timing.
    @ObservationIgnored private var elapsedTime: Float = 0

    // Touch physics constants
    private let touchRadius: Float       = 130.0  // points — influence radius around finger
    private let maxTouchBend: Float      = 0.90   // radians (~52°) at contact centre
    private let touchDecayRate: Float    = 3.5    // 1/s — spring-back speed once hold ends
    /// How long (seconds) a bent blade holds its position after the finger lifts,
    /// leaving a visible parted trail before springing back.
    private let trailHoldDuration: Float = 2.0

    /// Parallel to `blades` — the `elapsedTime` after which each blade may start
    /// its exponential spring-back. Initialised to `.infinity` so blades that are
    /// still being dragged over (even if in the outer radius) never accidentally
    /// decay before the finger has fully lifted. Set to `elapsedTime` in
    /// `touchesEnded` so the ENTIRE path holds simultaneously.
    @ObservationIgnored private var bladeHoldUntil: [Float] = []

    /// True for each blade that is currently under an active touch this frame.
    /// Used to skip decay for live-contact blades even if their hold timer expired.
    @ObservationIgnored private var bladePressedNow: [Bool] = []

    // Haptics — created initially without a view; wired to the live MTKView
    // via setupHapticGenerators(view:) once it enters the window hierarchy.
    // UIImpactFeedbackGenerator(style:view:) is required on iOS 17.5+ for the
    // Taptic Engine to resolve the correct UIWindowScene; the view-less init
    // silently produces no feedback on modern hardware.
    // @ObservationIgnored: these are UIKit implementation details — changes must
    // not trigger SwiftUI observation (they fire on every touch event).
    @ObservationIgnored private var impactFeedback = UIImpactFeedbackGenerator(style: .light)
    @ObservationIgnored private var softImpact     = UIImpactFeedbackGenerator(style: .soft)
    @ObservationIgnored private var hapticCooldown: Float = 0      // seconds until next haptic is allowed
    /// Re-arm the Taptic Engine every second so prepare() never expires
    /// mid-drag (the engine's armed window is only ~1-2 s on device).
    @ObservationIgnored private var hapticRearmAccumulator: Float = 0

    // MARK: - Init
    init() {
        Task { await regenerateField() }
    }

    // MARK: - Haptic Setup

    /// Wire the Taptic Engine to the live MTKView so iOS 17.5+ can route feedback
    /// through the correct UIWindowScene.  Call once from GrassRenderer.setup(device:view:)
    /// after the view is in the window hierarchy.
    func setupHapticGenerators(view: UIView) {
        impactFeedback = UIImpactFeedbackGenerator(style: .light, view: view)
        softImpact     = UIImpactFeedbackGenerator(style: .soft,  view: view)
        // Pre-arm both generators so the first touch fires without latency.
        impactFeedback.prepare()
        softImpact.prepare()
    }

    // MARK: - Field Generation
    func regenerateField() async {
        isGenerating = true
        let size = screenSize
        lastGeneratedSize = size   // record immediately to prevent duplicate triggers
        let density = settings.density
        let bladeHeight = settings.bladeHeight
        log.info("regenerateField: starting — screenSize=\(size.width)×\(size.height) density=\(density.bladeCount)")
        let newBlades = await Task.detached(priority: .userInitiated) {
            GrassFieldGenerator.generate(
                density: density,
                bladeHeight: bladeHeight,
                screenSize: size,
                seed: 42
            )
        }.value
        blades = newBlades
        fieldVersion &+= 1   // wrapping increment — renderer detects any change
        touchBendAngles = [Float](repeating: 0,        count: newBlades.count)
        bladeHoldUntil  = [Float](repeating: .infinity, count: newBlades.count)
        bladePressedNow = [Bool](repeating: false,     count: newBlades.count)
        bladeIndexMap = Dictionary(uniqueKeysWithValues:
            newBlades.indices.map { (newBlades[$0].id, $0) })
        spatialGrid = SpatialGrid(items: newBlades, cellSize: 40)
        isGenerating = false
        log.info("regenerateField: complete — \(newBlades.count) blades generated")
    }

    // MARK: - Per-Frame Update (called from GrassRenderer on main thread)
    func update(deltaTime: Float, screenSize: CGSize) {
        self.screenSize = screenSize
        elapsedTime += deltaTime
        if activeInteraction == .none {
            updateTouchBends(deltaTime: deltaTime)
        } else {
            updateInteractionEffects(deltaTime: deltaTime)
        }
        syncTimeOfDay(deltaTime: deltaTime)
        GrassAudioEngine.shared.updateVolumes(for: settings.timeOfDay)

        // Regenerate when the screen dimensions change significantly —
        // e.g. the device rotates between portrait and landscape.
        // Guard against re-triggering while a generation is already in flight.
        if !isGenerating, lastGeneratedSize != .zero {
            let widthDiff  = abs(screenSize.width  - lastGeneratedSize.width)
            let heightDiff = abs(screenSize.height - lastGeneratedSize.height)
            if widthDiff > 20 || heightDiff > 20 {
                lastGeneratedSize = screenSize   // prevent duplicate triggers
                // Nil seasonal systems so they're re-spawned for the new layout.
                leafSystem      = nil
                dandelionSystem = nil
                Task { await regenerateField() }
            }
        }
        // ── Seasonal systems ────────────────────────────────────────────────
        updateLeafSystem(deltaTime: deltaTime, screenSize: screenSize)
        updateDandelionSystem(deltaTime: deltaTime, screenSize: screenSize)

        #if DEBUG
        debugSpawnTick(deltaTime: deltaTime)
        #endif
    }

    #if DEBUG
    // Test-only: when `debugSpawnEffect` (UserDefaults) is "ripple"/"star"/
    // "footstep", auto-drives that effect so it can be screenshotted without
    // touch injection. Never runs unless the flag is set; compiled out of
    // release builds entirely.
    @ObservationIgnored private var debugFootPhase: Float = 0
    @ObservationIgnored private var debugFootStarted = false

    private func debugSpawnTick(deltaTime: Float) {
        guard let mode = UserDefaults.standard.string(forKey: "debugSpawnEffect"),
              !mode.isEmpty, screenSize.width > 0 else { return }

        let target: GrassInteraction = (mode == "star") ? .star
                                     : (mode == "footstep") ? .footstep : .ripple
        if activeInteraction != target { activeInteraction = target }

        let cx = Float(screenSize.width) * 0.5
        switch target {
        case .ripple, .star:
            // Respawn a fresh front each time the previous one clears, so a
            // ring is almost always mid-expansion when captured.
            if !interactionSystem.isActive {
                interactionSystem.spawnFront(
                    at: SIMD2(cx, Float(screenSize.height) * 0.42),
                    isStar: target == .star,
                    screenSize: screenSize,
                    rings: target == .star ? 2 : 3)
                interactionDirty = true
            }
        case .footstep:
            // Walk a slow horizontal S so a multi-print trail builds up.
            debugFootPhase += deltaTime
            let x = cx + Float(screenSize.width) * 0.32 * sin(debugFootPhase * 0.9)
            let y = Float(screenSize.height) * (0.40 + 0.16 * sin(debugFootPhase * 1.7))
            let p = SIMD2(x, y)
            if !debugFootStarted {
                interactionSystem.beginFootsteps(at: p)
                debugFootStarted = true
            } else {
                interactionSystem.moveFootsteps(to: p)
            }
            interactionDirty = true
        case .none:
            break
        }
    }
    #endif

    private func updateLeafSystem(deltaTime: Float, screenSize: CGSize) {
        if settings.currentSeason == .fall {
            if leafSystem == nil {
                leafSystem = LeafSystem(screenSize: screenSize)
            }
            let windAmp = settings.windSpeed.amplitudeMultiplier * 0.15 + 0.012
            leafSystem?.update(deltaTime: deltaTime,
                               windAmplitude: windAmp,
                               elapsedTime: elapsedTime,
                               screenSize: screenSize)
        } else if leafSystem != nil {
            leafSystem = nil
        }
    }

    private func updateDandelionSystem(deltaTime: Float, screenSize: CGSize) {
        if settings.currentSeason == .spring {
            if dandelionSystem == nil {
                dandelionSystem = DandelionSystem(screenSize: screenSize)
            }
            dandelionSystem?.update(deltaTime: deltaTime)
        } else if dandelionSystem != nil {
            dandelionSystem = nil
        }
    }

    // MARK: - Live Clock Sync

    /// Keeps `settings.timeOfDay` in step with the device clock.
    /// Runs at most once per second to avoid hammering Calendar on every frame.
    private func syncTimeOfDay(deltaTime: Float) {
        timeSyncAccumulator += deltaTime
        guard timeSyncAccumulator >= 1.0 else { return }
        timeSyncAccumulator = 0
        #if DEBUG
        // Test hook: pin a specific clock hour for deterministic screenshots.
        // `defaults write com.smeva.meadow debugTimeOfDay -double 12.0`.
        // Compiled out of release builds entirely.
        if let override = UserDefaults.standard.object(forKey: "debugTimeOfDay") as? Double {
            settings.timeOfDay = override
            return
        }
        #endif
        let comps  = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        let real   = Double(comps.hour ?? 12)
                   + Double(comps.minute ?? 0) / 60.0
                   + Double(comps.second ?? 0) / 3600.0
        // Apply the manual offset and wrap into [0, 24).
        var result = real + settings.manualTimeOffset
        result = result.truncatingRemainder(dividingBy: 24.0)
        if result < 0 { result += 24.0 }
        settings.timeOfDay = result
    }

    // MARK: - Touch Physics

    private func updateTouchBends(deltaTime: Float) {
        guard !touchBendAngles.isEmpty else { return }

        // ── Reset pressed flags ───────────────────────────────────────────────
        for i in bladePressedNow.indices { bladePressedNow[i] = false }

        var contactedBladeCount = 0

        // ── Apply active touches → update bend angles ─────────────────────────
        if !activeTouches.isEmpty, let grid = spatialGrid {
            for touch in activeTouches {
                let nearby = grid.items(near: touch.position, radius: touchRadius)
                for blade in nearby {
                    guard let index = bladeIndexMap[blade.id] else { continue }

                    let dx = blade.rootPosition.x - Float(touch.position.x)
                    let dy = blade.rootPosition.y - Float(touch.position.y)
                    let dist = (dx * dx + dy * dy).squareRoot()
                    guard dist < touchRadius else { continue }

                    let t = 1.0 - dist / touchRadius
                    let strength = t * t * maxTouchBend * blade.resistanceCoefficient
                    let dir: Float = dist > 1.0 ? dx / dist : 0

                    touchBendAngles[index] = dir * strength
                    bladePressedNow[index] = true
                    contactedBladeCount += 1
                }
            }
        }

        // ── Trail hold + spring-back ──────────────────────────────────────────
        // `bladeHoldUntil[i]` is set to `elapsedTime + trailHoldDuration` by
        // `touchesEnded`, so the ENTIRE path starts holding simultaneously the
        // instant the finger lifts — regardless of when each blade was last inside
        // the touch radius. While a blade is still under an active touch it is
        // skipped entirely.
        let decayFactor = exp(-touchDecayRate * deltaTime)
        for i in touchBendAngles.indices {
            guard touchBendAngles[i] != 0, !bladePressedNow[i] else { continue }
            if elapsedTime > bladeHoldUntil[i] {
                touchBendAngles[i] *= decayFactor
                if abs(touchBendAngles[i]) < 0.001 { touchBendAngles[i] = 0 }
            }
        }

        // ── Haptics ───────────────────────────────────────────────────────────
        // The Taptic Engine's "armed" window lasts only ~1-2 s after prepare().
        // Re-arm every second so long drags stay responsive.
        if settings.hapticsEnabled, !activeTouches.isEmpty {
            hapticRearmAccumulator += deltaTime
            if hapticRearmAccumulator >= 1.0 {
                hapticRearmAccumulator = 0
                impactFeedback.prepare()
                softImpact.prepare()
            }
        } else {
            hapticRearmAccumulator = 0
        }

        hapticCooldown -= deltaTime
        if settings.hapticsEnabled, hapticCooldown <= 0, contactedBladeCount > 0 {
            hapticCooldown = 0.10   // ~10 Hz max rate
            // Scale intensity: softer for sparse contacts, firmer for dense.
            let intensity = min(0.40 + CGFloat(contactedBladeCount) / 60.0, 0.80)
            if contactedBladeCount < 8 {
                softImpact.impactOccurred(intensity: intensity)
            } else {
                impactFeedback.impactOccurred(intensity: intensity)
            }
        }
    }

    // MARK: - Interaction Effects (Ripple / Foot step / Star)

    /// Advances the active interaction effects and writes their combined
    /// per-blade bend into `touchBendAngles` (consumed by the renderer just
    /// like the default touch bends). Runs only while an interaction is active.
    private func updateInteractionEffects(deltaTime: Float) {
        interactionSystem.update(deltaTime: deltaTime)
        guard !touchBendAngles.isEmpty else { return }

        if interactionSystem.isActive || interactionDirty {
            for i in touchBendAngles.indices { touchBendAngles[i] = 0 }
            interactionSystem.applyBends(blades: blades, into: &touchBendAngles)
            // One more zeroing pass is needed on the first idle frame after the
            // last effect expires; after that we can skip the work entirely.
            interactionDirty = interactionSystem.isActive
        }
    }

    // MARK: - Touch Input

    func touchesBegan(_ touches: [TouchPoint]) {
        #if DEBUG
        let p0 = touches.first?.position ?? .zero
        log.info("TOUCHDBG touchesBegan mode=\(self.activeInteraction.rawValue) n=\(touches.count) at=(\(Int(p0.x)),\(Int(p0.y))) size=\(Int(self.screenSize.width))x\(Int(self.screenSize.height))")
        #endif
        // Interaction modes intercept the touch to spawn an effect instead of
        // parting the grass.
        switch activeInteraction {
        case .ripple, .star:
            if let p = touches.first?.position {
                let isStar = activeInteraction == .star
                interactionSystem.spawnFront(at: SIMD2(Float(p.x), Float(p.y)),
                                             isStar: isStar,
                                             screenSize: screenSize,
                                             rings: isStar ? 2 : 3)   // tap → multi-ring burst
                interactionDirty = true
                fireSpawnHaptic()
            }
            return
        case .footstep:
            if let p = touches.first?.position {
                interactionSystem.beginFootsteps(at: SIMD2(Float(p.x), Float(p.y)))
                interactionDirty = true
                fireStepHaptic()
            }
            return
        case .none:
            break
        }
        defaultTouchesBegan(touches)
    }

    /// Default behaviour: register touches so the grass parts under the finger.
    private func defaultTouchesBegan(_ touches: [TouchPoint]) {
        activeTouches.append(contentsOf: touches)
        guard settings.hapticsEnabled else { return }
        // Arm both generators immediately and fire a subtle initial tap
        // so the engine is warm for the drag that follows.
        impactFeedback.prepare()
        softImpact.prepare()
        softImpact.impactOccurred(intensity: 0.35)
        hapticRearmAccumulator = 0   // reset re-arm clock from this touch
    }

    func touchesMoved(_ touches: [TouchPoint]) {
        // Seasonal systems always react to dragging, regardless of mode.
        for touch in touches {
            leafSystem?.touchMoved(at: touch.position)
            dandelionSystem?.touchMoved(at: touch.position)
        }

        if activeInteraction == .footstep {
            if let p = touches.first?.position {
                let stamped = interactionSystem.moveFootsteps(to: SIMD2(Float(p.x), Float(p.y)))
                interactionDirty = true
                if stamped > 0 { fireStepHaptic() }
            }
            return
        }
        guard activeInteraction == .none else { return }

        for touch in touches {
            if let index = activeTouches.firstIndex(where: { $0.id == touch.id }) {
                activeTouches[index] = touch
            }
        }
    }

    func touchesEnded(_ ids: Set<ObjectIdentifier>) {
        if activeInteraction == .footstep {
            interactionSystem.endFootsteps()
            return
        }
        guard activeInteraction == .none else { return }

        activeTouches.removeAll { ids.contains($0.id) }

        // Stamp every currently-bent blade so the whole drag path starts its
        // hold period simultaneously from this exact moment.  Blades still under
        // a remaining finger will be re-bent each frame and skipped by the decay
        // guard, so stamping them here is harmless.
        let holdUntil = elapsedTime + trailHoldDuration
        for i in touchBendAngles.indices where touchBendAngles[i] != 0 {
            bladeHoldUntil[i] = holdUntil
        }
    }

    // MARK: - Interaction Haptics

    /// Firm tap when a Ripple or Star is spawned.
    private func fireSpawnHaptic() {
        guard settings.hapticsEnabled else { return }
        impactFeedback.prepare()
        impactFeedback.impactOccurred(intensity: 0.7)
    }

    /// Light tick for each footstep laid down.
    private func fireStepHaptic() {
        guard settings.hapticsEnabled else { return }
        softImpact.impactOccurred(intensity: 0.5)
        softImpact.prepare()
    }

    // MARK: - Season
    func advanceSeason() {
        let current = settings.currentSeason
        let next = current.next
        seasonTransition = SeasonTransitionState(
            from: current.palette,
            to: next.palette,
            duration: 1.5
        )
        settings.currentSeason = next
        // TODO: Phase 6 — drive colour interpolation each frame
    }
}

// MARK: - Supporting Types

struct TouchPoint: Identifiable {
    let id: ObjectIdentifier   // stable identity tied to the UITouch object
    var position: CGPoint
    var velocity: CGVector
}

struct SeasonTransitionState {
    let from: SeasonPalette
    let to: SeasonPalette
    let duration: Float
    var elapsed: Float = 0
    var progress: Float { min(elapsed / duration, 1.0) }
}
