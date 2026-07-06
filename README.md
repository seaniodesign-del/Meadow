# 🌱 Meadow

A living, breathing meadow in your pocket. Meadow renders a full-screen field of
thousands of individual grass blades in real time with Metal, reacts to touch,
follows the time of day, and changes with the seasons — a calm, interactive
ambient experience for iOS.

> **Status:** active development · iOS 26 · Swift 6.2

---

## ✨ Features

- **GPU grass field** — thousands of individually simulated blades rendered with a
  custom Metal pipeline (instanced draw, per-blade wind, tilt, and bend).
- **Touch interaction** — drag through the grass to part it; blades bend away from
  your finger and spring back with a trailing hold.
- **Live day/night cycle** — the palette tracks the device clock through hand-tuned
  keyframes (sunrise, midday, golden hour, dusk, night), including a street-lamp
  glow and fireflies after dark.
- **Seasons** — each with its own look and life:
  - **Spring** — dandelions (3-D mesh) that scatter on touch
  - **Summer** — lush deep-green field
  - **Fall** — fully 3-D autumn leaves that fall, tumble, settle, and scatter
  - **Winter** — dormant, sun-bleached dry-grass palette
- **Onboarding season dial** — a liquid-glass rotary dial (iOS 26 Liquid Glass) to
  pick your season on launch, with stepped haptics and a blur-in season name.
- **Interaction menu** — pick a grass effect and play:
  - **Ripple** — a tap sends concentric rings expanding outward through the grass
  - **Foot step** — drag to leave a staggered trail of pressed footprints
  - **Star** — a tap radiates a 5-pointed expanding disturbance
- **Ambient audio** — day/night music beds that cross-fade with the clock.
- **Haptics** — Taptic feedback wired through the live `UIWindowScene` for drag,
  selection, and effect spawns.

---

## 🧱 Tech stack

| Area | Choice |
|------|--------|
| UI | SwiftUI (`@Observable` MVVM, `@MainActor`) |
| Rendering | Metal + MetalKit (`MTKView`), custom `.metal` shaders |
| Concurrency | Swift 6.2 strict concurrency, `async/await` |
| Project gen | [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml`) |
| Packages (SPM) | [Vortex](https://github.com/twostraws/Vortex), [Model3DView](https://github.com/frzi/swiftui-model3dview) |
| Min target | iOS 26.0 |

---

## 📂 Project structure

```
Meadow/
├── project.yml                 # XcodeGen project definition (source of truth)
├── Meadow/
│   ├── App/                    # App entry point, ContentView
│   ├── Core/
│   │   ├── Audio/              # Ambient music engine
│   │   ├── Haptics/            # Taptic feedback
│   │   └── Physics/            # Spatial grid, Perlin noise, generators
│   ├── Features/
│   │   ├── GrassField/
│   │   │   ├── Metal/          # GrassRenderer, MetalView, .metal shaders, meshes
│   │   │   ├── Models/         # Blade, Season, TimeOfDay, Leaf/Dandelion systems,
│   │   │   │                   #   GrassInteraction(+System)
│   │   │   ├── ViewModels/     # GrassFieldViewModel (physics + orchestration)
│   │   │   └── Views/          # Overlay, settings, interaction menu, UI components
│   │   └── Onboarding/         # Season dial + onboarding flow
│   └── Resources/              # Info.plist, assets, leaf textures, audio
├── MeadowTests/                # Unit tests (Swift Testing / XCTest)
└── docs/                       # Spec + implementation tasks
```

---

## 🚀 Build & run

**Requirements:** macOS with **Xcode 26**, iOS 26 SDK.

The Xcode project is committed, so the fastest path is:

```bash
open Meadow.xcodeproj
# Select an iOS 26 simulator (e.g. iPhone 17 Pro) → ⌘R
```

If you change the file layout, regenerate the project from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen   # once
xcodegen generate       # rebuilds Meadow.xcodeproj from project.yml
```

Swift packages (Vortex, Model3DView) resolve automatically on first build.

> **Tip:** if Xcode ever launches a stale build after external edits, run
> **Product → Clean Build Folder (⇧⌘K)** before ⌘R.

---

## 🎮 Using the interaction menu

1. On launch, spin the **season dial** and tap **Start**.
2. In the main view, tap a card in the bottom menu: **Ripple**, **Foot step**, or **Star**
   (the active card shows a white ring).
3. **Ripple / Star:** tap anywhere on the grass to send an effect expanding outward.
   **Foot step:** drag across the grass to lay a trail of footprints.
4. Tap the active card again to return to plain grass-parting.

The gear (top-left) opens settings (wind, density, blade height, sound, haptics);
the season chip (top-right) switches season live.

---

## 🧪 Testing

Unit tests live in `MeadowTests/`. Run them from Xcode (⌘U) or the command line:

```bash
xcodebuild test -project Meadow.xcodeproj -scheme Meadow \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Core physics/logic (grass generation, spatial grid, effect math) is the primary
test surface; view logic is kept in view models to stay testable.

---

## 🗺️ Notes & limitations

- The grass blade shader bends blades along the screen-x axis, so radial effects
  (ripple/star) read strongest on the left/right of the ring — tuned via the
  `frontDirFloor` constant so the ring stays continuous.
- Some `#if DEBUG`-only hooks exist for previewing effects and pinning the clock
  during screenshots; they compile out of release builds.

---

## 📄 License

See [`LICENSE`](LICENSE) (add one if distributing).

🤖 Repository scaffolding, docs, and changelog generated with
[Claude Code](https://claude.com/claude-code).
