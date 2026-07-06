# Changelog

All notable changes to **Meadow** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project aims to follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- **Ripple & Star** intensity reduced ~20% (`frontAmp` 1.8 → 1.44) for a softer disturbance.

### Fixed
- **Foot step trail** no longer merges into a single smear. Prints were spaced
  closer than their own size; spacing, offset, and shape were retuned so the trail
  now reads as distinct, staggered left/right footprints
  (`strideLen` 46 → 66, `lateral` 14 → 23, elongated print shape, longer lifetime).

## [1.0.0] — 2026-07-06

Initial tracked release. Everything below is present in this first versioned snapshot.

### Added — Grass engine
- Real-time Metal grass field: thousands of instanced blades with per-blade wind,
  tilt, taper, colour variation, and directional lighting.
- Touch interaction: blades bend away from the finger via a per-blade bend angle,
  with a spatial grid for O(k) touch queries and a trailing spring-back hold.
- CPU-rendered tree-shadow mask sampled by the blade fragment shader.

### Added — Time of day
- Season-aware day/night palette driven by the live device clock through hand-tuned
  keyframes (midnight → pre-dawn → sunrise → midday → golden hour → dusk).
- Off-screen street-lamp glow (shader radial attenuation) and a firefly ambient
  overlay after dark.

### Added — Seasons
- **Spring:** dandelions rendered from a decimated 3-D mesh; scatter on touch.
- **Summer:** lush deep-green palette.
- **Fall:** fully 3-D autumn leaf meshes (7 species) that fall, tumble in 3-D, land,
  rest, and scatter under touch/gusts.
- **Winter:** dedicated warm, sun-bleached dry-grass day-cycle palette.

### Added — Onboarding
- Liquid-glass rotary **season dial** (iOS 26 Liquid Glass) shown on launch:
  drag to rotate, snaps to the nearest season, blur-in season name.
- Stepped selection haptics during drag; a confirming impact on commit.
- Dark transparent glass surface; evenly spaced dial ticks; a fixed highlight halo
  that icons and ticks rotate *through* (world-space brightness).

### Added — Interaction menu
- Bottom menu with three toggleable grass effects, each a Liquid-Glass card with a
  3 pt white selection ring:
  - **Ripple** — a tap emits concentric rings expanding outward until off-screen.
  - **Foot step** — dragging lays a staggered trail of pressed footprints
    (max 5 pairs, fading over their lifetime).
  - **Star** — a tap emits a 5-pointed expanding disturbance.
- All effects drive the same per-blade bend the shader already consumes, so they
  layer over wind and self-clear.

### Added — App & platform
- SwiftUI `@Observable` MVVM architecture, `@MainActor`, Swift 6.2 concurrency.
- Ambient day/night music engine with clock-driven cross-fade.
- Settings sheet: wind speed, density, blade height, sound, haptics.
- XcodeGen project definition (`project.yml`); SPM dependencies (Vortex, Model3DView).
- Portrait + landscape support with field regeneration on rotation.

### Fixed (during development)
- **Black screen:** Metal draw calls were silently rejected because fragment
  uniforms were uploaded with `MemoryLayout.size` (88 B) instead of `.stride`
  (96 B); the struct is 16-byte aligned.
- **App Store validation:** added the full-screen requirement so restricted
  orientations validate.
- **Stale Xcode builds:** documented the clean-build workflow after external edits.

---

[Unreleased]: https://github.com/seaniodesign-del/Meadow/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/seaniodesign-del/Meadow/releases/tag/v1.0.0
