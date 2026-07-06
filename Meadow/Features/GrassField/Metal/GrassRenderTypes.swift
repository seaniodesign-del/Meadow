import simd
import UIKit
import SwiftUI

// MARK: - Swift mirrors of Metal struct layouts
// These must exactly match the structs in GrassShaders.metal.

/// One vertex of the shared blade quad (4 vertices, drawn as triangleStrip).
struct BladeVertex {
    var position: SIMD2<Float>    // blade-local x ∈ [-0.5, 0.5], y ∈ [0, 1]
    var normalizedHeight: Float   // 0 = root, 1 = tip
}

/// Per-instance data uploaded to the GPU each frame.
/// Layout must match `BladeInstance` in GrassShaders.metal.
struct BladeInstanceData {
    var rootPosition: SIMD2<Float>   // screen-space points
    var height: Float
    var baseWidth: Float
    var bendAngle: Float             // total: wind + touch
    var colourVariant: Float
    var baseTilt: Float
}

/// Uploaded once per render pass as vertex buffer(2).
/// Layout must match `VertexUniforms` in GrassShaders.metal.
struct GrassVertexUniforms {
    var screenSize: SIMD2<Float>
    var positionOffset: SIMD2<Float>  // (0,0) for blade pass; offset for shadow pass
    var time: Float                   // elapsed seconds, drives wind animation
    var windAmplitude: Float          // 0 = still, ~0.15 gentle, ~0.27 breezy (radians)
    var timeOfDay: Float              // clock hour in [0, 24) — drives streak position & intensity
}

/// Uploaded once per blade pass as fragment buffer(0).
/// Layout must match `FragmentUniforms` in GrassShaders.metal.
/// Using SIMD4 (not SIMD3) avoids Metal float3 alignment surprises.
///
/// Memory layout (.size = 88, .stride = 96):
///   offset  0 – 79: five SIMD4<Float> colour fields (16 B each)
///   offset 80 – 87: screenSize SIMD2<Float> (8 B)
///   offset 88 – 95: 8 B trailing padding (Metal aligns struct to 16 B, largest member)
/// Always pass MemoryLayout<GrassFragmentUniforms>.stride (96) to setFragmentBytes.
struct GrassFragmentUniforms {
    var baseColour:   SIMD4<Float>   // offset  0
    var midColour:    SIMD4<Float>   // offset 16
    var tipColour:    SIMD4<Float>   // offset 32
    var groundColour: SIMD4<Float>   // offset 48 — fades blade roots into background
    var sunColour:    SIMD4<Float>   // offset 64 — additive tint for sunlight streaks
    var screenSize:   SIMD2<Float>   // offset 80 — used by grassFragment for shadow UV
}

// MARK: - Colour helpers

extension Color {
    /// Convert a SwiftUI Color to a Metal-ready SIMD4<Float> (rgba, linear-ish).
    var metalRGBA: SIMD4<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
    }
}

extension SeasonPalette {
    var fragmentUniforms: GrassFragmentUniforms {
        GrassFragmentUniforms(
            baseColour:   baseColour.metalRGBA,
            midColour:    midColour.metalRGBA,
            tipColour:    tipColour.metalRGBA,
            groundColour: groundColour.metalRGBA,
            sunColour:    sunColour.metalRGBA,
            screenSize:   .zero   // overwritten by GrassRenderer each frame
        )
    }

    /// MTLClearColor derived from groundColour so the view background always
    /// matches the colour that blade roots fade into.
    var metalClearColor: MTLClearColor {
        let c = groundColour.metalRGBA
        return MTLClearColorMake(Double(c.x), Double(c.y), Double(c.z), 1.0)
    }
}

// MARK: - Leaf render types

/// Per-instance data for a single fallen leaf, uploaded every frame.
/// Layout must exactly match `LeafInstance` in GrassShaders.metal.
/// Swift MemoryLayout: size = 36, stride = 40 (SIMD2<Float> forces 8-byte alignment,
/// leaving 4 bytes of implicit tail padding; Metal uses explicit _pad to match).
struct LeafInstanceData {
    var position:      SIMD2<Float>   // screen-space centre, in points     [offset  0, 8 B]
    var rotation:      Float          // radians — combines resting angle + flutter [offset  8, 4 B]
    var scale:         Float          // uniform scale: base size in points  [offset 12, 4 B]
    var brightness:    Float          // per-leaf brightness multiplier [0.7…1.1]   [offset 16, 4 B]
    var opacity:       Float          // 0 = fully transparent, 1 = fully opaque    [offset 20, 4 B]
    var textureIndex:  UInt32         // 0–6 — selects leaf type from texture array [offset 24, 4 B]
    var tilt:          Float          // 3-D tilt angle (radians)                   [offset 28, 4 B]
    var groundY:       Float          // screen-space Y where leaf rests             [offset 32, 4 B]
    // Swift implicit tail padding: 4 B → stride = 40 bytes
}

/// Uploaded once per leaf render pass as vertex buffer(2).
/// Layout must match `LeafVertexUniforms` in GrassShaders.metal.
struct LeafVertexUniforms {
    var screenSize:    SIMD2<Float>
    var time:          Float          // elapsed seconds, drives gentle flutter
    var windAmplitude: Float          // mirrors grass wind amplitude
    var shadowOffset:  SIMD2<Float>   // (0,0) for colour pass; sun-offset for shadow pass
}

// MARK: - Dandelion render types

/// Per-instance data for a single dandelion, uploaded every frame.
/// Layout must exactly match `DandelionInstance` in GrassShaders.metal.
/// Stride = 40 bytes: SIMD2<Float> forces 8-byte struct alignment,
/// so the 9-field / 36-byte payload is padded to 40 (Metal adds implicit _pad).
struct DandelionInstanceData {
    var rootPosition:  SIMD2<Float>   // screen-space root position          [offset  0, 8 B]
    var height:        Float          // stem height in points               [offset  8, 4 B]
    var puffRadius:    Float          // puff sphere radius in points        [offset 12, 4 B]
    var bendAngle:     Float          // touch-driven bend (radians)         [offset 16, 4 B]
    var windPhase:     Float          // per-dandelion phase offset          [offset 20, 4 B]
    var colourVariant: Float          // subtle stem colour variation [0,1]  [offset 24, 4 B]
    var seedOpacity:   Float          // puff fullness [0=bare, 1=full]      [offset 28, 4 B]
    var rotation:      Float          // screen-space orientation (radians)  [offset 32, 4 B]
    // Swift implicit tail padding: 4 B → stride = 40 bytes
}

/// Uploaded once per dandelion pass as vertex buffer(2).
/// Layout must match `DandelionVertexUniforms` in GrassShaders.metal.
/// Stride = 24 bytes (SIMD2<Float> + four Floats).
struct DandelionVertexUniforms {
    var screenSize:    SIMD2<Float>   // [offset  0, 8 B]
    var time:          Float          // [offset  8, 4 B]
    var windAmplitude: Float          // [offset 12, 4 B]
    var timeOfDay:     Float          // [offset 16, 4 B]  clock hour [0, 24) — drives lighting
    var shadowSlantX:  Float          // [offset 20, 4 B]  0 = colour pass; ~0.5 = shadow pass
}

/// Uploaded once per dandelion mesh draw call as fragment buffer(0).
/// Layout must match `DandelionMeshUniforms` in GrassShaders.metal.
/// Stride = 32 bytes: SIMD4<Float> forces 16-byte alignment; colour(16) +
/// timeOfDay(4) = 20 bytes, padded to 32.
struct DandelionMeshUniforms {
    var colour:    SIMD4<Float>
    var timeOfDay: Float          // clock hour [0, 24) — drives night dimming
}

// MARK: - Blade data helper

extension GrassBlade {
    /// Convert to GPU instance data. bendAngle is supplied by the physics system.
    func instanceData(bendAngle: Float = 0) -> BladeInstanceData {
        BladeInstanceData(
            rootPosition: rootPosition,
            height:       height,
            baseWidth:    baseWidth,
            bendAngle:    bendAngle,
            colourVariant: colourVariant,
            baseTilt:     baseTilt
        )
    }
}
