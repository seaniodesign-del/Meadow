# Implementation Tasks: Meadow — Interactive Grass

**Spec:** `docs/spec.md`
**Status:** In Progress

---

## Progress Summary
- Total Phases: 9
- Completed: 1
- Current: Phase 2

---

## Phase 1: Project Foundation & Metal Setup ✅

### Step 1.1 — XcodeGen & Project Bootstrap ✅
- [x] Install XcodeGen: `brew install xcodegen`
- [x] Run `xcodegen generate` in project root
- [x] Verify `.xcodeproj` opens and builds cleanly
- [x] Configure bundle ID, deployment target (iOS 26.0), portrait lock
- [x] Metal toolchain downloaded and verified

### Step 1.2 — MetalView Wrapper ✅
- [x] Implement `MetalView: UIViewRepresentable` wrapping `MTKView`
- [x] CADisplayLink-driven loop (stays @MainActor, ProMotion-ready at 120fps)
- [x] `TouchForwarder` protocol for UIKit touch passthrough

### Step 1.3 — App Shell ✅
- [x] `MeadowApp.swift` — app entry, portrait lock via Info.plist
- [x] `ContentView.swift` — `ZStack` with `MetalView` (full screen, `.ignoresSafeArea()`) + overlay
- [x] `statusBarHidden` + `persistentSystemOverlays(.hidden)` for full immersion

**Phase 1 complete:** Clean build on iOS 26 Simulator. Dark-green Metal canvas + CADisplayLink running @120fps.

---

## Phase 2: Static Grass Field Rendering

### Step 2.1 — Blade Geometry
- [ ] Define `GrassBlade` struct (position, height, width, baseTilt, colourVariant, resistanceCoeff)
- [ ] Write `BladeGeometryBuilder` — generates 4-vertex triangle strip with Bezier curve baked in
- [ ] Confirm single blade renders correctly in isolation

### Step 2.2 — Field Generation
- [ ] Implement `PerlinNoise` (2D, seeded) in `Core/Physics/PerlinNoise.swift`
- [ ] Implement `GrassFieldGenerator` — 8×8pt grid + Perlin clustering → array of `GrassBlade`
- [ ] Target ~2,500 blades for normal density on iPhone 15
- [ ] Generate field off main thread; publish result via `@Observable`

### Step 2.3 — Instanced Rendering
- [ ] Create Metal vertex/fragment shaders in `GrassShaders.metal`
  - Vertex: accepts per-instance position, tilt, height, bend angle
  - Fragment: base-to-tip colour gradient (dark base → bright tip)
- [ ] Build `GrassRenderer` — creates `MTLBuffer` from blade array, issues instanced draw call
- [ ] Implement depth sorting (painter's algorithm, by Y position + height)

### Step 2.4 — Ground & Shadow
- [ ] Ground pass: solid `#0d2205` clear colour
- [ ] Per-blade drop shadow: second instanced draw at slight offset, dark semi-transparent
- [ ] Tune shadow length and opacity for depth realism

**Phase 2 done when:** Full screen of static, varied, shadowed grass blades render at 60fps.

---

## Phase 3: Wind Animation

### Step 3.1 — Wind Field
- [ ] Implement `WindField` — time-evolving 2D Perlin noise sampled per-blade per-frame
- [ ] Wind parameters: speed (0–breezy), direction (slow drift cycle 20–40s), gust events
- [ ] Expose `windBendAngle(for blade: GrassBlade, at time: Float) -> Float`

### Step 3.2 — Blade Sway
- [ ] Pass wind bend angle into per-instance GPU data each frame
- [ ] Verify blades sway naturally without snapping; tune Perlin frequency and amplitude
- [ ] Implement calm period logic (5s calm → gentle gust cycle)

### Step 3.3 — Wind Settings Integration
- [ ] Connect `GrassSettings.windSpeed` enum to wind amplitude multiplier
- [ ] Off = zero wind; Gentle = default; Breezy = 1.8× amplitude

**Phase 3 done when:** Grass sways gently with no touch, responds to wind speed setting.

---

## Phase 4: Touch Interaction

### Step 4.1 — Touch Input Pipeline
- [ ] Add `UIGestureRecognizer` (or direct `touchesBegan/Moved/Ended` override) on MetalView
- [ ] Expose active touch points as `[(id: UUID, position: CGPoint, velocity: CGVector)]` on `GrassFieldViewModel`
- [ ] Confirm multi-touch (up to 5 simultaneous) captured correctly

### Step 4.2 — Spatial Grid
- [ ] Implement `SpatialGrid<T>` — bucket blades into 40pt cells for O(1) neighbour lookup
- [ ] `bladesNear(point: CGPoint, radius: Float) -> [GrassBlade]` returns blades in influence zone
- [ ] Unit test in `GrassPhysicsTests.swift`

### Step 4.3 — Bend Physics
- [ ] Implement `TouchInfluence` — computes `bendAngle` and `flattenFactor` per blade per touch
- [ ] Formula: `bendAngle = maxBend × (1 - dist/radius)^1.5 × blade.resistanceCoeff`
- [ ] Random per-blade ±8° variation applied on first touch contact (stable per touch)
- [ ] Overlapping multi-touch: additive bend, capped at 90°

### Step 4.4 — GPU Integration
- [ ] Merge touch bend + wind bend into single per-instance bend angle uploaded to GPU each frame
- [ ] Verify real-time response feels immediate (< 16ms from touch to visual)

**Phase 4 done when:** Dragging a finger bends grass away naturally; multi-touch works.

---

## Phase 5: Spring-Back Physics

### Step 5.1 — Damped Harmonic Oscillator
- [ ] Implement `SpringPhysics` — damped harmonic oscillator per blade
  - `stiffness: 8.0`, `damping: 0.65`
  - Integrate with fixed timestep (frame delta capped at 33ms)
- [ ] Verify slight overshoot and natural settle

### Step 5.2 — Hold Delay
- [ ] On touch lift, each affected blade enters a `holdDelay` state (0.2–0.6s, randomised per blade)
- [ ] After delay expires, spring-back begins
- [ ] Staggered delays produce ripple-like recovery across the touched area

### Step 5.3 — State Machine
- [ ] `BendState` enum: `.resting`, `.touched(angle)`, `.holding(angle, remainingDelay)`, `.recovering(spring: SpringState)`
- [ ] State machine driven each frame in `GrassFieldViewModel`

**Phase 5 done when:** Lifting finger causes blades to hold flat briefly then spring back naturally with stagger.

---

## Phase 6: Seasons

### Step 6.1 — Season Data Model
- [ ] `Season` enum: `.spring`, `.summer`, `.fall`, `.winter`
- [ ] `SeasonPalette` struct per season: baseColour, tipColour, groundColour, shadowOpacity
- [ ] Persist selected season in `UserDefaults`

### Step 6.2 — Colour Transition
- [ ] `SeasonTransitionState` — interpolates between two `SeasonPalette` values over 1.5s
- [ ] Upload lerped colours to GPU each frame during transition
- [ ] Transition triggered when user taps season button

### Step 6.3 — Season-Specific Effects
- [ ] **Spring:** Random dew glint animation on 5% of blades (brief alpha pulse on tip)
- [ ] **Fall:** `FallingLeaf` particle — single leaf shape drifts across screen; spawns every 30–60s
- [ ] **Winter:** Frost overlay on blade tips (white tint on top 15% of blade length); snow particle system (very sparse, gentle drift)

**Phase 6 done when:** All 4 seasons render correctly and transition smoothly.

---

## Phase 7: Audio

### Step 7.1 — AVAudioEngine Setup
- [ ] `GrassAudioEngine` singleton using `AVAudioEngine`
- [ ] Audio session: `.ambient` category, `.mixWithOthers` option
- [ ] Activate session; handle interruptions (phone calls, etc.)

### Step 7.2 — Procedural Rustling
- [ ] `AVAudioSourceNode` generating white noise
- [ ] `AVAudioUnitEQ` band-pass filter centred at 1.2kHz, Q=2.5
- [ ] Amplitude envelope driven by `dragVelocityMagnitude` from `GrassFieldViewModel`
- [ ] Up to 3 voices for multi-touch (one per active fast-moving touch)
- [ ] 0.4s fade-out on touch end

### Step 7.3 — Wind Ambient
- [ ] Low-volume (~15%) continuous subtle noise loop during wind sway
- [ ] Volume scales with wind speed setting

### Step 7.4 — Settings Integration
- [ ] Sound toggle in settings disables/enables `GrassAudioEngine`

**Phase 7 done when:** Dragging produces convincing rustling sound; ambient wind audio plays.

---

## Phase 8: Haptics & UI

### Step 8.1 — Haptics
- [ ] `HapticsManager` wrapping `UIImpactFeedbackGenerator`
- [ ] Touch begin: `.light` impact
- [ ] Drag pulse: `.soft` impact every 0.35s when velocity > threshold
- [ ] Haptics toggle in settings

### Step 8.2 — Season Button
- [ ] `SeasonButton` view — pill shape, `.ultraThinMaterial`, 44×44pt min tap target
- [ ] Cycles season on tap; displays current season SF Symbol / emoji
- [ ] Positioned bottom-right with safe area inset

### Step 8.3 — Settings Sheet
- [ ] `SettingsSheet` half-sheet view with all controls (wind, density, haptics, sound, blade height)
- [ ] Two-way bind to `GrassSettings` `@Observable` model
- [ ] Density change: debounce 0.5s then trigger off-thread field regeneration

### Step 8.4 — Button Fade Behaviour
- [ ] Both buttons at 100% opacity by default
- [ ] Fade to 20% opacity after 3s of no UI interaction
- [ ] Restore to 100% on tap near bottom of screen
- [ ] Animate with `.easeInOut(duration: 0.4)`

**Phase 8 done when:** Both buttons work, settings persist, haptics fire correctly.

---

## Phase 9: Polish & Performance

### Step 9.1 — ProMotion Support
- [ ] Set `preferredFramesPerSecond = 0` on MTKView (auto-selects 120fps on ProMotion)
- [ ] Verify physics timestep is frame-rate independent

### Step 9.2 — Performance Profiling
- [ ] Profile with Instruments (GPU, CPU, memory) on iPhone 15
- [ ] Target: stable 60fps during 5-finger drag
- [ ] Optimise: reduce overdraw, batch static blade buffer updates

### Step 9.3 — Accessibility
- [ ] VoiceOver label on grass canvas
- [ ] Reduce Motion support in `SpringPhysics` and wind sway
- [ ] Reduce Transparency fallback for buttons

### Step 9.4 — Edge Cases & Stability
- [ ] App backgrounding: pause Metal loop, suspend audio, stop haptics
- [ ] App foregrounding: resume all
- [ ] Low memory warning: reduce blade count gracefully
- [ ] Test on iPhone 15, 15 Pro, 16 Pro

**Phase 9 done when:** Stable 60/120fps, all accessibility options work, no crashes on lifecycle events.

---

## Changes Log
| Date | Phase | Changes |
|------|-------|---------|
| 2026-04-22 | All | Initial task breakdown created |
