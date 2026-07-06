# Meadow — Interactive Grass App

## Quick Reference
- **Platform:** iOS 26+ / iPhone 15 and beyond
- **Language:** Swift 6.2
- **UI Framework:** SwiftUI + Metal (MTKView)
- **Architecture:** MVVM with @Observable
- **Orientation:** Portrait only
- **Spec:** `docs/spec.md`
- **Tasks:** `docs/tasks/implementation-tasks.md`

## Project Structure
```
Meadow/
├── App/                        # Entry point
├── Features/GrassField/
│   ├── Views/                  # SwiftUI views + UI overlays
│   ├── ViewModels/             # @Observable view models
│   ├── Models/                 # Data models (GrassBlade, Season, etc.)
│   └── Metal/                  # MTKView wrapper + Metal renderer
├── Core/
│   ├── Physics/                # PerlinNoise, SpringPhysics, SpatialGrid
│   ├── Audio/                  # GrassAudioEngine (AVAudioEngine)
│   └── Haptics/                # HapticsManager
└── Resources/
```

## Key Architecture Decisions
- Grass rendering is **Metal-only** — do not use Canvas or SwiftUI drawing for blades
- All blade state lives in `GrassFieldViewModel` (@MainActor @Observable)
- Physics runs on the **main thread** (frame-synced); field generation runs **off main thread**
- `SpatialGrid` must be used for all touch-radius lookups — never iterate all blades
- `AVAudioEngine` audio session category: `.ambient` (mixes with user music)

## Build Commands
- Build: `mcp__xcodebuildmcp__build_sim_name_proj`
- Test: `mcp__xcodebuildmcp__test_sim_name_proj`
- Run: `mcp__xcodebuildmcp__launch_app`

## Performance Targets
- 60fps iPhone 15 / 120fps ProMotion at all times
- < 16ms touch-to-visual latency
- < 120MB memory

## DO NOT
- Use UIKit directly (except MTKView wrapper and UIImpactFeedbackGenerator)
- Iterate all blades for touch lookup — always use SpatialGrid
- Block the main thread during field generation or density changes
- Use ObservableObject / @Published — always use @Observable
- Hard-code blade positions — always use the seeded Perlin layout generator
