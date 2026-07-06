# Feature Specification: Interactive Grass

**Status:** Draft
**Platform:** iOS 26+ (iPhone 15 and beyond)
**Orientation:** Portrait only
**Last Updated:** April 22, 2026

---

## 1. Overview

A full-screen, immersive iOS experience that simulates a realistic top-down view of a grass field. The user can reach down and interact with the grass using their fingers — bending, parting, and flattening blades with natural physics. The app is purely relaxing and sensory with no game mechanics. The grass fills the entire screen like a living wallpaper.

---

## 2. Visual Design

### Camera & Perspective
- **Top-down (orthographic birds-eye) view** looking straight down onto the grass field
- No horizon, no sky — 100% grass filling the entire screen edge-to-edge
- The grass surface is perceived as 3D through depth cues: shadow, contrast, layering, and tilt

### Grass Appearance
- Each blade is rendered as a **narrow polygon** (tapered quadrilateral/thin triangle) with a slight natural curve
- Blades vary in:
  - **Height:** 3 size bands — short (6–10pt), medium (10–16pt), tall (16–24pt) — distributed randomly with natural clustering
  - **Width:** 1.5–3.5pt at base, tapering to a point
  - **Base tilt:** Resting lean angle ±25° from vertical using seeded randomness
  - **Green shade:** `#1a4a0a` (deep shadow base) → `#4caf0a` (bright tip), darker at base, brighter at tip
- Blades are **depth-sorted** so taller blades appear in front of shorter ones
- **Density:** ~2,000–3,500 visible blades per screen

### Depth & Shadow
- Each blade has a soft **drop shadow**, elongated away from simulated overhead light (slightly off-centre upper-left)
- Ground beneath: `#0d2205` (very dark green) visible between blades
- Blade brightness varies per current bend angle (more vertical = brighter tip)

### Seasons
| Season | Grass Color | Special Effects |
|--------|-------------|-----------------|
| **Summer** *(default)* | Deep rich green | None |
| **Spring** | Bright lime-green tips, lighter overall | Dew sparkle glints on blade tips |
| **Fall** | Green-to-amber gradient; 20% blades dry/golden | Rare falling leaf drifts across screen (30–60s interval) |
| **Winter** | Desaturated grey-green | Frosted white tips on ~30% of blades; faint snow particle overlay |

Season transitions animate over **1.5 seconds** via colour interpolation across all blades.

---

## 3. Grass Rendering

### Technology
- **Metal** via custom `MTKView` wrapped in `UIViewRepresentable`
- Each blade: **triangle strip mesh** (4–6 vertices) with Bezier curve baked into vertex positions
- **Instanced rendering** — one draw call per blade type; per-instance data for position, height, tilt, colour variation, bend state
- Blade field generated once at launch using seeded layout algorithm; stored in GPU vertex buffer

### Layout Algorithm
- Screen divided into **8×8pt grid cells**; each cell contains 1–3 blade roots with randomised offsets
- **Perlin noise field** drives clustering — denser and sparser patches mimic natural growth
- Blade root positions fixed; only bend state changes at runtime

---

## 4. Physics & Interaction

### Touch Response
- Touch creates a **circular influence zone** (~40pt radius)
- Bend direction: **away from touch point**
- `bendAngle = maxBend × (1 - distance/radius)^1.5`; maxBend = 75°
- Blades near centre also **flattened** (compressed apparent height)

### Randomness & Variation
- Each blade has a **resistance coefficient** (0.7–1.3) — some stiffer, some more yielding
- **Random bend offset** ±8° per blade prevents perfectly uniform sweep
- Multi-touch: each finger independent; overlapping zones use additive (capped) force

### Spring-Back
- **Phase 1 — Hold:** Blade stays flat for 0.2–0.6s (randomised per blade)
- **Phase 2 — Recovery:** Damped harmonic oscillator (`stiffness: 8, damping: 0.65`); slight overshoot
- Total recovery: ~1.0–2.2s depending on bend amount
- Staggered recovery timing creates a natural ripple effect across the touch area

### Wind (Idle State)
- Slowly-moving 2D Perlin noise field drives ±12° oscillating sway
- Wind direction shifts over 20–40s full cycle
- Occasional calm periods (~5s) followed by slightly stronger gusts

---

## 5. Audio

### Rustling Sound
- Procedural via `AVAudioEngine`: white noise → band-pass filter at ~1.2kHz → amplitude shaped by drag velocity
- Volume/bandwidth scale with **finger drag speed**; fades out over ~0.4s when touch ends
- Up to 3 simultaneous rustling voices for multi-touch
- **Wind ambient loop:** ~15% max volume during idle wind sway

### Audio Session
- Category: `.ambient` — respects silent mode, mixes with user's music

---

## 6. Haptics

- `UIImpactFeedbackGenerator` with `.light` style
- **Touch begin:** Single soft impact pulse on first contact
- **Continuous drag:** Single `.soft` pulse every ~0.35s only when drag velocity exceeds threshold
- **Spring-back:** No haptic on recovery

---

## 7. UI Components

Both buttons live in the bottom portion of the screen. Style: frosted glass (`.ultraThinMaterial`), semi-transparent. Both fade to **20% opacity** after 3 seconds of inactivity, returning to full on touch.

### Season Button (Bottom Right)
- Pill-shaped button with season icon: 🌱 Spring / ☀️ Summer / 🍂 Fall / ❄️ Winter
- Tap cycles through seasons with 1.5s colour transition

### Settings Button (Bottom Left)
- `gear` SF Symbol, same frosted glass style
- Opens half-sheet (`presentationDetents: [.medium]`) with:
  - **Wind Speed:** Slider (Off → Gentle → Breezy)
  - **Grass Density:** Slider (Sparse → Normal → Dense) — triggers off-thread regeneration
  - **Haptics:** Toggle
  - **Sound:** Toggle
  - **Blade Height:** Slider (Short → Tall)
- Settings persist via `UserDefaults`

---

## 8. Performance Requirements

| Metric | Target |
|--------|--------|
| Frame rate | 60fps iPhone 15; 120fps ProMotion devices |
| Touch latency | < 16ms first blade response |
| Memory | < 120MB total |
| Launch time | < 1.5s to first interactive frame |

### Optimisations
- Spatial grid for O(1) blade lookup within touch radius
- Only visible viewport blades submitted to GPU
- Static blades batched; only bending/recovering blades updated per-frame
- Density changes regenerated off main thread

---

## 9. Accessibility

- VoiceOver: Canvas labeled "Interactive grass field. Swipe to interact."
- Reduce Motion: Simplified linear animations (no oscillation)
- Reduce Transparency: Solid dark-green fallback for buttons

---

## 10. Out of Scope (v1.0)

- Landscape orientation
- iPad support
- Insects, flowers, or other scene elements
- Day/night lighting cycle
- Recording/sharing screenshots
- Android

---

## Open Questions

- [ ] App name confirmed as "Meadow"?
- [ ] Season button: cycle on tap, or show 4-option picker?
- [ ] Recorded grass sound sample needed, or procedural only?
