#include <metal_stdlib>
using namespace metal;

// MARK: - Per-instance data (one entry per grass blade, uploaded each frame)
struct BladeInstance {
    float2 rootPosition;    // screen-space, in points
    float  height;          // blade height in points
    float  baseWidth;       // blade base width in points
    float  bendAngle;       // total bend: wind + touch, in radians
    float  colourVariant;   // 0 = darkest individual tint, 1 = brightest
    float  baseTilt;        // resting lean angle, in radians
};

// MARK: - Vertex stage uniforms (one upload per render pass)
struct VertexUniforms {
    float2 screenSize;      // screen dimensions in points
    float2 positionOffset;  // (0,0) for blade pass; shadow offset for shadow pass
    float  time;            // elapsed time in seconds, for wind animation
    float  windAmplitude;   // 0 = still, ~0.15 = gentle, ~0.27 = breezy (radians)
    float  timeOfDay;       // clock hour in [0, 24) — drives street-lamp attenuation
};

// MARK: - Fragment stage uniforms (season palette colours)
struct FragmentUniforms {
    float4 baseColour;      // rgb = root colour,           a = unused
    float4 midColour;       // rgb = middle colour,         a = unused
    float4 tipColour;       // rgb = tip colour,            a = unused
    float4 groundColour;    // rgb = background colour,     a = unused
    float4 sunColour;       // rgb = sunlight streak tint,  a = unused
    float2 screenSize;      // screen dimensions in points; used to compute shadow UV
};

// MARK: - Vertex shader I/O
struct VertexIn {
    float2 position          [[attribute(0)]];  // blade-local: x in [-0.5, 0.5], y in [0, 1]
    float  normalizedHeight  [[attribute(1)]];  // 0 = root, 1 = tip
};

struct VertexOut {
    float4 clipPosition      [[position]];
    float  normalizedHeight;
    float  colourVariant;
    float  lightFactor;      // 1 = fully lit, <1 = darkened by sideways tilt
    float  lampFactor;       // 0 = no lamp, >0 = blade lit by street lamp
    float2 screenPos;        // world-space position in points (y = 0 at screen top)
};

// MARK: - Vertex shader
vertex VertexOut grassVertex(
    VertexIn in                            [[stage_in]],
    constant BladeInstance*   instances   [[buffer(1)]],
    constant VertexUniforms&  uniforms    [[buffer(2)]],
    uint instanceID                        [[instance_id]]
) {
    BladeInstance blade = instances[instanceID];

    // ── Wind animation ────────────────────────────────────────────────────
    float2 pos = blade.rootPosition;

    // Wind direction drifts slowly so gusts arrive from varying angles
    // rather than always travelling left→right.
    float windAngle = uniforms.time * 0.11 + sin(uniforms.time * 0.07) * 0.7;
    float wdx = cos(windAngle);          // along-wind  X component
    float wdy = sin(windAngle);          // along-wind  Y component

    // Decompose blade position into along-wind and cross-wind distances.
    float along = pos.x * wdx  + pos.y * wdy;
    float cross  = pos.x * (-wdy) + pos.y * wdx;

    // Primary sweep: broad wave that travels along the current wind direction.
    float sweep = sin(along * 0.022 + uniforms.time * 0.88);

    // Cross-wind amplitude envelope: blades at different cross-wind positions
    // peak at different moments, breaking up perfectly straight wave fronts.
    float crossEnv = 0.55 + 0.45 * sin(cross * 0.038 + uniforms.time * 0.45);
    sweep *= crossEnv;

    // Turbulence: two small waves at different oblique angles so the chaotic
    // micro-motion has its own spatial structure unrelated to the main sweep.
    float t1 = sin(pos.x * 0.063 + pos.y * 0.041 + uniforms.time * 2.4)  * 0.20;
    float t2 = sin(pos.x * 0.029 - pos.y * 0.057 + uniforms.time * 1.75) * 0.16;

    // Per-blade phase jitter: two-frequency position hash gives every blade
    // a unique timing offset so blades at equal projected distances don't
    // move in lockstep.
    float jitter = sin(pos.x * 0.127 + pos.y * 0.163) * M_PI_F
                 + cos(pos.x * 0.091 - pos.y * 0.209) * M_PI_F;
    float micro  = sin(uniforms.time * 3.3 + jitter) * 0.09;

    // Gust envelope: regional amplitude breathes along the wind direction.
    float gust = 0.65 + 0.70 * (0.5 + 0.5 * sin(along * 0.009 + uniforms.time * 0.21));

    // blade.bendAngle is reserved for touch bending.
    float windBend = (sweep + t1 + t2 + micro) * gust * uniforms.windAmplitude;

    // Progressive bend: angle increases from base (0) to tip (1)
    float angle = blade.baseTilt + (blade.bendAngle + windBend) * in.normalizedHeight;

    // 2D rotation matrix (column-major)
    float2x2 rot = float2x2(
        float2( cos(angle), sin(angle)),
        float2(-sin(angle), cos(angle))
    );

    // Taper: full width at base, ~18% at tip
    float2 localPos = float2(
        in.position.x * blade.baseWidth * (1.0 - in.normalizedHeight * 0.82),
        -in.normalizedHeight * blade.height
    );

    // World position in point-space, with optional shadow offset
    float2 worldPos = blade.rootPosition + rot * localPos + uniforms.positionOffset;

    // To clip space: normalise to [0,1] then to [-1,1], flip Y (Metal Y+ = up)
    float2 clipPos = (worldPos / uniforms.screenSize) * 2.0 - 1.0;
    clipPos.y = -clipPos.y;

    // ── Directional lighting from top-left ────────────────────────────────
    float diffuse = 0.45 + 0.55 * max(0.0, sin(angle + M_PI_F * 0.25));

    // ── Street lamp (implied, left side) ─────────────────────────────────
    // The lamp post is off-screen to the left at eye level. Its light falls
    // on the grass as a radial attenuation from that source — the same
    // additive-on-grass technique used by the sun streaks above, but driven
    // by distance rather than sin bands. Active from 8 PM (20:00).
    //
    // Lamp source: x = -0.75 × screen width (well off left edge)
    //              y = 0.28 × screen height (above mid — eye level of post top)
    float lampFadeIn   = smoothstep(20.0, 20.33, uniforms.timeOfDay);
    float lampFadeOut  = 1.0 - smoothstep(23.8, 24.0, uniforms.timeOfDay);
    float lampGate     = lampFadeIn * lampFadeOut;

    float2 lampPos    = float2(-uniforms.screenSize.x * 0.75,
                                uniforms.screenSize.y * 0.28);
    float  lampDist   = length(pos - lampPos);
    // Broad radius — about 2.5 × screen width — so the warm glow reaches
    // across most of the field with a convincing fall-off gradient.
    float  lampRadius = uniforms.screenSize.x * 2.5;
    float  lampAtten  = max(0.0, 1.0 - lampDist / lampRadius);
    // Cubic falloff: tighter bright core, gentle tail to the right edge
    lampAtten = lampAtten * lampAtten * lampAtten;
    // +25% overall brightness vs a linear-falloff baseline
    float lampFactor  = min(lampAtten * lampGate * 1.25, 1.0);

    VertexOut out;
    out.clipPosition     = float4(clipPos, 0.0, 1.0);
    out.normalizedHeight = in.normalizedHeight;
    out.colourVariant    = blade.colourVariant;
    out.lightFactor      = diffuse;
    out.lampFactor       = lampFactor;
    // Pass world-space position (points, y = 0 at top) for shadow UV lookup.
    out.screenPos        = worldPos;
    return out;
}

// MARK: - Blade fragment shader
fragment float4 grassFragment(
    VertexOut                        in         [[stage_in]],
    constant FragmentUniforms&       uni        [[buffer(0)]],
    texture2d<float, access::sample> shadowMask [[texture(0)]]
) {
    float h = in.normalizedHeight;

    // ── Four-stop gradient: ground → base → mid → tip ───────────────────
    float t = pow(h, 0.65);
    float3 colour = mix(uni.baseColour.rgb, uni.midColour.rgb,
                        min(t * 2.0, 1.0));
    colour        = mix(colour, uni.tipColour.rgb,
                        max(t * 2.0 - 1.0, 0.0));

    // Fade the blade root into the background over the bottom 20% of height.
    float rootFade = smoothstep(0.0, 0.20, h);
    colour = mix(uni.groundColour.rgb, colour, rootFade);

    // ── Directional light from top-left (pre-computed per-vertex) ────────
    colour *= in.lightFactor;

    // ── Per-blade brightness variation ────────────────────────────────────
    colour *= 0.80 + in.colourVariant * 0.40;

    // ── Specular tip highlight ─────────────────────────────────────────────
    float tipMask  = smoothstep(0.58, 1.0, h);
    float specular = tipMask * in.colourVariant * in.lightFactor * 0.28;
    colour += uni.tipColour.rgb * specular;

    // ── Street lamp illumination ──────────────────────────────────────────
    // Warm amber-yellow — the characteristic sodium-vapour colour of a
    // distant street lamp.  Ramps up from the root (0.05) to a broad mid-
    // and tip region (0.80) so lit blades look naturally back-lit from the left.
    float3 lampColour = float3(1.0, 0.87, 0.42);
    float  lampHeight = smoothstep(0.05, 0.80, h);
    colour += lampColour * in.lampFactor * lampHeight;

    // ── Tree shadow ───────────────────────────────────────────────────────
    // Sample the pre-rendered, soft-edge shadow mask (¼-res .r8Unorm texture).
    // screenPos is in screen-space points (y = 0 at top), so dividing by
    // screenSize gives a UV that maps correctly to the shadow texture.
    // shadowAmt ∈ [0, ~0.55], matching the opacity curves in GrassShadowMask.
    // mix() replicates the original TreeShadowView overlay exactly:
    //   finalColour = (1 − opacity) × colour + opacity × shadowTint
    // where shadowTint ≈ (0.005, 0.018, 0.003) — the same dark-green used in TreeShadowView.
    constexpr sampler shadowSampler(address::clamp_to_edge, filter::linear);
    float2 shadowUV  = in.screenPos / uni.screenSize;
    float  shadowAmt = shadowMask.sample(shadowSampler, shadowUV).r;
    float3 shadowTint = float3(0.005, 0.018, 0.003);
    colour = mix(colour, shadowTint, shadowAmt);

    return float4(colour, 1.0);
}

// MARK: - Shadow fragment shader
// Dense drop-shadow projected bottom-right from each blade root,
// simulating the top-left sun casting shadows across the ground.
fragment float4 grassShadowFragment(VertexOut in [[stage_in]]) {
    float t     = 1.0 - in.normalizedHeight;
    float alpha = 0.72 * t * t;
    return float4(0.008, 0.018, 0.004, alpha);
}

// ══════════════════════════════════════════════════════════════════════════════
// MARK: - Fallen Leaf Shaders
// ══════════════════════════════════════════════════════════════════════════════

// MARK: - Leaf instance + uniforms structs

/// Must match LeafInstanceData in GrassRenderTypes.swift (stride = 40 bytes).
struct LeafInstance {
    float2 position;       // screen-space centre (points)       [offset  0]
    float  rotation;       // radians                            [offset  8]
    float  scale;          // uniform size in points             [offset 12]
    float  brightness;     // per-leaf brightness multiplier     [offset 16]
    float  opacity;                                           //  [offset 20]
    uint   textureIndex;   // 0–6 → slice in leafTextures array  [offset 24]
    float  tilt;           // 3-D tilt angle: 0=face-on, ±π/2=edge-on [offset 28]
    float  groundY;        // screen-space Y where this leaf rests     [offset 32]
    float  _pad;           // explicit padding → stride = 40           [offset 36]
};

struct LeafVertexUniforms {
    float2 screenSize;
    float  time;
    float  windAmplitude;
    float2 shadowOffset;   // (0,0) for colour pass; sun-direction offset for shadow pass
};

// MARK: - Leaf vertex I/O

struct LeafVertexOut {
    float4 clipPosition  [[position]];
    float2 texUV;          // [0,1]² UV into the leaf texture
    float  brightness;
    float  opacity;
    uint   textureIndex  [[flat]];   // flat: no interpolation for integers
    float  cosTilt;        // cos(tilt): 1=face-on, 0=edge-on, negative=back-face
};

// MARK: - Leaf vertex shader

vertex LeafVertexOut leafVertex(
    VertexIn                        in          [[stage_in]],
    constant LeafInstance*          instances   [[buffer(1)]],
    constant LeafVertexUniforms&    uniforms    [[buffer(2)]],
    uint                            instanceID  [[instance_id]]
) {
    LeafInstance leaf = instances[instanceID];

    // Two-frequency flutter so the visual sway matches the physics rocking.
    // Second harmonic breaks up the metronomic feel of a single sine wave.
    float f1      = sin(uniforms.time * 2.1 + leaf.rotation * 1.9);
    float f2      = sin(uniforms.time * 3.8 + leaf.rotation * 0.7) * 0.45;
    float flutter = (f1 + f2) * uniforms.windAmplitude * 0.35;
    float angle   = leaf.rotation + flutter;

    float2x2 rot = float2x2(
        float2( cos(angle), sin(angle)),
        float2(-sin(angle), cos(angle))
    );

    // ── 3-D foreshortening ────────────────────────────────────────────────
    // A leaf tilted edge-on (tilt ≈ ±π/2) should look thin; face-on (tilt ≈ 0)
    // should show its full area. cos(tilt) gives the foreshortening factor in Y.
    float cosTilt      = cos(leaf.tilt);
    // Clamp foreshortening to at least 0.35 so the leaf silhouette stays readable
    // even when nearly edge-on — prevents leaves collapsing to invisible thin lines.
    float absCos       = max(0.35, abs(cosTilt));

    // Shared quad: position ∈ [-0.5, 0.5] × [0, 1]
    // Remap to centred [-0.5, 0.5]² for rotation.
    // Y is compressed by absCos so the leaf thins as it tilts edge-on.
    float2 localCentred = float2(in.position.x, (in.position.y - 0.5) * absCos);

    // ── Isometric shadow projection ───────────────────────────────────────
    // uniforms.shadowOffset encodes the sun direction as a per-unit-height factor:
    //   colour pass  → shadowOffset = (0, 0)  → origin stays at leaf.position
    //   shadow pass  → shadowOffset = (lateral, 1.0)
    //                  origin.x shifts right by height × lateral (sun azimuth)
    //                  origin.y projects fully to groundY (height × 1.0)
    // Result: a resting leaf's shadow coincides with the leaf (height = 0),
    // while a falling leaf's shadow appears on the ground far below it.
    float heightAboveGround = max(0.0, leaf.groundY - leaf.position.y);
    float2 shadowOrigin = float2(
        leaf.position.x + heightAboveGround * uniforms.shadowOffset.x,
        leaf.position.y + heightAboveGround * uniforms.shadowOffset.y
    );
    float2 worldPos = shadowOrigin + rot * (localCentred * leaf.scale);

    // UV is independent of foreshortening so the texture doesn't stretch.
    float2 uv = float2(in.position.x + 0.5, 1.0 - in.position.y);

    float2 clipPos = (worldPos / uniforms.screenSize) * 2.0 - 1.0;
    clipPos.y      = -clipPos.y;

    LeafVertexOut out;
    out.clipPosition = float4(clipPos, 0.0, 1.0);
    out.texUV        = uv;
    out.brightness   = leaf.brightness;
    out.opacity      = leaf.opacity;
    out.textureIndex = leaf.textureIndex;
    out.cosTilt      = cosTilt;
    return out;
}

// MARK: - Leaf fragment shader

fragment float4 leafFragment(
    LeafVertexOut                          in           [[stage_in]],
    texture2d_array<float, access::sample> leafTextures [[texture(0)]],
    constant float&                        timeOfDay    [[buffer(0)]]
) {
    constexpr sampler s(address::clamp_to_zero, filter::linear);

    float4 tex    = leafTextures.sample(s, in.texUV, in.textureIndex);
    float  alpha  = tex.a * in.opacity;
    if (alpha < 0.02) discard_fragment();

    // Apply per-leaf brightness variation on top of the photographic colour.
    float3 colour = tex.rgb * in.brightness;

    // ── Tilt-based front/back lighting ────────────────────────────────────
    // cosTilt ≈ +1  → face-on from above, full brightness
    // cosTilt ≈  0  → edge-on, half brightness
    // cosTilt ≈ -1  → back-face from below, dark with slight warm-grey SSS tint
    if (in.cosTilt >= 0.0) {
        // Front face: ramp from dim (edge-on) to bright (face-on).
        float topLight = 0.45 + 0.55 * in.cosTilt;
        colour *= topLight;
    } else {
        // Back face: dark underside with a desaturated, slightly warm quality
        // that hints at sub-surface light transmission.
        float backIntensity = 0.25 + 0.15 * (-in.cosTilt);
        float grey = dot(colour, float3(0.299, 0.587, 0.114));
        colour = mix(colour, float3(grey * 1.1), 0.5);
        colour *= backIntensity;
    }

    // ── Night dimming ─────────────────────────────────────────────────────
    // Leaves should be very difficult to see at night (~15% of daytime brightness).
    // Smooth transitions: dawn 4:30–7:30, dusk 19:30–22:00.
    float dawn     = smoothstep(4.5, 7.5, timeOfDay);
    float dusk     = 1.0 - smoothstep(19.5, 22.0, timeOfDay);
    float nightDim = 0.15 + 0.85 * min(dawn, dusk);
    colour *= nightDim;

    return float4(colour, alpha);
}

// MARK: - Leaf shadow fragment shader
// Renders a soft dark silhouette of each leaf projected in the sun direction.
// Uses the same foreshortened geometry as the colour pass so a nearly edge-on
// leaf casts a narrow shadow, while a face-on leaf casts a full broad shadow.
fragment float4 leafShadowFragment(
    LeafVertexOut                              in           [[stage_in]],
    texture2d_array<float, access::sample>    leafTextures [[texture(0)]]
) {
    constexpr sampler s(address::clamp_to_zero, filter::linear);
    float4 tex        = leafTextures.sample(s, in.texUV, in.textureIndex);
    // Shadow intensity fades to zero as the leaf tilts edge-on (cosTilt → 0).
    float shadowFade  = abs(in.cosTilt);
    float alpha       = tex.a * in.opacity * 0.45 * shadowFade;
    if (alpha < 0.015) discard_fragment();
    // Very dark green-black to match the grass shadow colour scheme.
    return float4(0.004, 0.012, 0.002, alpha);
}

// ══════════════════════════════════════════════════════════════════════════════
// MARK: - Dandelion Shaders (spring season)
// ══════════════════════════════════════════════════════════════════════════════

// MARK: - Dandelion structs

/// Must match DandelionInstanceData in GrassRenderTypes.swift (stride = 40 bytes).
struct DandelionInstance {
    float2 rootPosition;   // screen-space root (points)        [offset  0]
    float  height;         // stem height in points             [offset  8]
    float  puffRadius;     // puff sphere radius in points      [offset 12]
    float  bendAngle;      // touch-driven bend (radians)       [offset 16]
    float  windPhase;      // per-dandelion phase offset        [offset 20]
    float  colourVariant;  // subtle colour variation [0,1]     [offset 24]
    float  seedOpacity;    // puff fullness [0=bare, 1=full]    [offset 28]
    float  rotation;       // screen-space facing angle (rad)   [offset 32]
    float  _pad;           // explicit tail padding → stride=40 [offset 36]
};

/// Must match DandelionVertexUniforms in GrassRenderTypes.swift (stride = 24 bytes).
struct DandelionVertexUniforms {
    float2 screenSize;
    float  time;
    float  windAmplitude;
    float  timeOfDay;     // clock hour [0, 24) — drives street-lamp attenuation
    float  shadowSlantX;  // 0 = colour pass; ~0.5 = shadow pass (projects to ground)
};

// MARK: - Shared wind helper
//
// Returns the bend at normalizedHeight = 1 (tip).  Callers multiply by
// normalizedHeight for the standard progressive-bend convention.
// Dandelions are stiffer than grass (×0.55) but share the same wave phase
// so they move in sync with the surrounding field.

float dandelionWindBend(float2 pos, float windPhase, float windAmplitude, float time) {
    float windAngle = time * 0.11 + sin(time * 0.07) * 0.7;
    float along     = pos.x * cos(windAngle) + pos.y * sin(windAngle);

    float sweep = sin(along * 0.022 + time * 0.88) * 0.55;

    float jitter = sin(pos.x * 0.127 + pos.y * 0.163 + windPhase) * M_PI_F;
    float micro  = sin(time * 2.8 + jitter) * 0.10;

    float gust = 0.70 + 0.55 * (0.5 + 0.5 * sin(along * 0.009 + time * 0.21));

    return (sweep + micro) * gust * windAmplitude * 0.55;
}

// ── 3-D mesh shaders ────────────────────────────────────────────────────────

// MARK: - Dandelion mesh vertex layout
//
// Each vertex in DandelionMesh.swift is 6 × Float32 (stride = 24 bytes):
//   float3 position  (Y-up model space, unit height ≈ 1.0)  offset  0
//   float3 normal                                            offset 12
//
// The vertex descriptor in GrassRenderer maps these via attribute(0) and
// attribute(1) in buffer slot 0.

struct DandelionMeshVertex {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
};

struct DandelionMeshOut {
    float4 clipPosition [[position]];
    float  lightFactor; // base diffuse
    float  modelY;      // 0 = root, ~1 = tip — root-fade alpha + height-based lamp ramp
    float  lampFactor;  // pre-computed street-lamp intensity at this vertex
};

/// Passed once per draw call as fragment buffer(0) to select the part colour.
/// Layout must match `DandelionMeshUniforms` in GrassRenderTypes.swift.
/// Stride = 32 bytes: float4 (16B) + float (4B) + 12B implicit padding.
struct DandelionMeshUniforms {
    float4 colour;
    float  timeOfDay;  // clock hour [0, 24) — drives night dimming
};

// MARK: - Dandelion mesh vertex shader
//
// Projects a Y-up unit-height model into screen space with the same
// progressive wind bend used by the rest of the grass field.
//
// Projection
//   model Y → -screen Y (flip; screen Y+ is downward)
//   model X → screen X  (direct lateral offset)
//   model Z →  slight isometric depth cue added to screen X
//
// Bending: standard cantilever approximation.
// At model height `my`, accumulated bend = bend × my.
//
// Shadow pass (uniforms.shadowSlantX > 0)
//   Each vertex is projected onto the ground plane along the sun direction:
//     shadowX = worldX + heightAboveGround × shadowSlantX
//     shadowY = rootPosition.y  (flattened onto the grass surface)
//   This produces a naturally elongated, distorted ground shadow matching the
//   sun direction used by the rest of the field.
//
// Lighting — replicates grassVertex for full scene consistency:
//   • Diffuse    — normal-dot-light
//   • Sun streaks — three diagonal sin bands, 13:00–21:00
//   • Street lamp — radial attenuation from upper-left, 20:00–24:00

vertex DandelionMeshOut dandelionMeshVertex(
    DandelionMeshVertex               in         [[stage_in]],
    constant DandelionInstance*       instances  [[buffer(1)]],
    constant DandelionVertexUniforms& uniforms   [[buffer(2)]],
    uint                              instanceID [[instance_id]]
) {
    DandelionInstance d = instances[instanceID];

    float windBend = dandelionWindBend(d.rootPosition, d.windPhase,
                                       uniforms.windAmplitude, uniforms.time);

    float my        = in.position.y;                          // [0, ~1] model height
    float totalBend = (d.bendAngle + windBend) * my;          // progressive bend

    // Bent spine (screen-space offset from root).
    float spineX = sin(totalBend) * my * d.height;
    float spineY = -cos(totalBend) * my * d.height;           // negative = upward

    // Cross-section: direct X + subtle isometric Z shift, then rotated in
    // screen space so each dandelion faces a different direction.
    float crossX = in.position.x * d.height;
    float isoX   = in.position.z * d.height * 0.12f;
    float crossW = crossX + isoX;
    float cosR   = cos(d.rotation);
    float sinR   = sin(d.rotation);
    float rotCrossX = crossW * cosR;
    float rotCrossY = crossW * sinR;

    float2 worldPos = float2(
        d.rootPosition.x + spineX + rotCrossX,
        d.rootPosition.y + spineY + rotCrossY
    );

    // ── Lamp lighting ─────────────────────────────────────────────────────
    // Use the true (un-shadowed) world position so lamp falloff is evaluated
    // at the actual location of the dandelion, not its shadow.
    float2 lightPos = float2(d.rootPosition.x + spineX, d.rootPosition.y + spineY);

    // Street lamp — identical formula to grassVertex
    float lampFadeIn  = smoothstep(20.0f, 20.33f, uniforms.timeOfDay);
    float lampFadeOut = 1.0f - smoothstep(23.8f, 24.0f, uniforms.timeOfDay);
    float lampGate    = lampFadeIn * lampFadeOut;
    float2 lampPos    = float2(-uniforms.screenSize.x * 0.75f,
                                uniforms.screenSize.y * 0.28f);
    float  lampDist   = length(lightPos - lampPos);
    float  lampRadius = uniforms.screenSize.x * 2.5f;
    float  lampAtten  = max(0.0f, 1.0f - lampDist / lampRadius);
    lampAtten         = lampAtten * lampAtten * lampAtten;
    float lampFactor  = min(lampAtten * lampGate * 1.25f, 1.0f);

    // Diffuse: model-space normal dot fixed top-left sun direction.
    float3 lightDir    = normalize(float3(-0.5f, 1.0f, -0.7f));
    float  diffuse     = max(0.0f, dot(in.normal, lightDir));
    float  lightFactor = 0.40f + 0.60f * diffuse;

    // ── Shadow projection ──────────────────────────────────────────────────
    // In the shadow pass shadowSlantX > 0: project every vertex onto the
    // ground plane along the sun direction, producing a distorted shadow whose
    // footprint correctly reflects the stem's bent pose and puff radius.
    float heightAboveGround = max(0.0f, d.rootPosition.y - worldPos.y);
    if (uniforms.shadowSlantX > 0.0f) {
        worldPos.x += heightAboveGround * uniforms.shadowSlantX;
        worldPos.y  = d.rootPosition.y;   // flatten onto the grass surface
    }

    float2 clipPos = (worldPos / uniforms.screenSize) * 2.0f - 1.0f;
    clipPos.y = -clipPos.y;

    DandelionMeshOut out;
    out.clipPosition = float4(clipPos, 0.0f, 1.0f);
    out.lightFactor  = lightFactor;
    out.modelY       = my;
    out.lampFactor   = lampFactor;
    return out;
}

// MARK: - Dandelion mesh colour fragment shader

fragment float4 dandelionMeshFragment(
    DandelionMeshOut                in  [[stage_in]],
    constant DandelionMeshUniforms& uni [[buffer(0)]]
) {
    float3 colour = uni.colour.rgb * in.lightFactor;

    // ── Street-lamp illumination ───────────────────────────────────────────
    // Sodium-vapour amber; same colour as the grass lamp tint.
    float3 lampColour = float3(1.0f, 0.87f, 0.42f);
    float  lampHeight = smoothstep(0.05f, 0.80f, in.modelY);
    colour += lampColour * in.lampFactor * lampHeight * 0.50f;

    // ── Night dimming ─────────────────────────────────────────────────────
    // Dandelions dim by 35% at deep night. Smooth transitions at dawn/dusk.
    float dawn      = smoothstep(4.5f, 7.5f, uni.timeOfDay);
    float dusk      = 1.0f - smoothstep(19.5f, 22.0f, uni.timeOfDay);
    float nightDim  = 0.65f + 0.35f * min(dawn, dusk);
    colour *= nightDim;

    // Fade the very base into the ground so the stem emerges smoothly.
    float rootFade = smoothstep(0.0f, 0.05f, in.modelY);

    return float4(colour, uni.colour.a * rootFade);
}

// MARK: - Dandelion mesh shadow fragment shader
//
// Renders each mesh part's ground projection as a soft dark silhouette.
// Opacity scales with the part's model height so the puff casts a denser
// shadow than the thin stem base, and the root dissolves into the surface.

fragment float4 dandelionMeshShadowFragment(DandelionMeshOut in [[stage_in]]) {
    float rootFade = smoothstep(0.0f, 0.06f, in.modelY);

    // Puff-height parts (my > 0.7) cast a slightly softer shadow than the stem.
    float densityFade = in.modelY > 0.7f ? 0.55f : 0.80f;

    float alpha = 0.50f * densityFade * rootFade;
    // Dark green-black matching the grass and leaf shadow palette.
    return float4(0.005f, 0.015f, 0.003f, alpha);
}

// MARK: - 3-D Leaf Mesh Rendering

/// Vertex input from the 3-D leaf mesh buffer.
/// Stride 32 B: float3 position + float3 normal + float2 uv.
struct LeafMeshVertex {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
};

/// Per-instance data — matches LeafInstanceData in GrassRenderTypes.swift (stride 40).
struct LeafMeshInstance {
    float2 position;      // screen-space centre (points)      [offset  0]
    float  rotation;      // in-plane orientation (radians)    [offset  8]
    float  scale;         // uniform scale in points           [offset 12]
    float  brightness;    // per-leaf brightness [0.7…1.1]     [offset 16]
    float  opacity;       // [offset 20]
    uint   textureIndex;  // species (handled by renderer)     [offset 24]
    float  tilt;          // 3-D tilt around leaf X axis (rad) [offset 28]
    float  groundY;       // screen Y where leaf rests         [offset 32]
    float  _pad;          // explicit pad → stride 40          [offset 36]
};

struct LeafMeshVertexOut {
    float4 clipPosition [[position]];
    float2 uv;
    float3 worldNormal;   // transformed normal, used for lighting
    float  brightness;
    float  opacity;
};

vertex LeafMeshVertexOut leaf3DVertex(
    LeafMeshVertex              meshVert    [[stage_in]],
    constant LeafMeshInstance*  instances   [[buffer(1)]],
    constant LeafVertexUniforms& uniforms   [[buffer(2)]],
    uint instanceID [[instance_id]])
{
    LeafMeshInstance leaf = instances[instanceID];

    // ── Gentle wind flutter (in-plane oscillation) ────────────────────────────
    float f1      = sin(uniforms.time * 2.1f + leaf.rotation * 1.9f);
    float f2      = sin(uniforms.time * 3.8f + leaf.rotation * 0.7f) * 0.45f;
    float flutter = (f1 + f2) * uniforms.windAmplitude * 0.10f;
    float angle   = leaf.rotation + flutter;

    // ── Scale mesh to screen points ───────────────────────────────────────────
    float3 pos = meshVert.position * leaf.scale;
    float3 nrm = meshVert.normal;

    // ── Tilt: rotate around leaf's X axis (spine direction) ──────────────────
    // tilt=0 → face-on (full leaf visible); tilt=±π/2 → edge-on (thin strip).
    float ct = cos(leaf.tilt), st = sin(leaf.tilt);
    float3 tilted = float3(
        pos.x,
        pos.y * ct - pos.z * st,
        pos.y * st + pos.z * ct
    );
    float3 tiltedNrm = float3(
        nrm.x,
        nrm.y * ct - nrm.z * st,
        nrm.y * st + nrm.z * ct
    );

    // ── In-plane rotation: rotate (x, z) by `angle` around screen Z ──────────
    float cr = cos(angle), sr = sin(angle);
    float2 screenLocal = float2(
        tilted.x * cr - tilted.z * sr,
        tilted.x * sr + tilted.z * cr
    );
    float2 rotNrm2D = float2(
        tiltedNrm.x * cr - tiltedNrm.z * sr,
        tiltedNrm.x * sr + tiltedNrm.z * cr
    );

    // ── Shadow pass: project leaf centre to ground level ─────────────────────
    float heightAboveGround = max(0.0f, leaf.groundY - leaf.position.y);
    float2 shadowOrigin = float2(
        leaf.position.x + heightAboveGround * uniforms.shadowOffset.x,
        leaf.position.y + heightAboveGround * uniforms.shadowOffset.y
    );
    float2 worldPos = shadowOrigin + screenLocal;

    // ── Clip space (orthographic) ─────────────────────────────────────────────
    float2 clipPos = (worldPos / uniforms.screenSize) * 2.0f - 1.0f;

    LeafMeshVertexOut out;
    out.clipPosition = float4(clipPos.x, -clipPos.y, 0.0f, 1.0f);
    out.uv           = meshVert.uv;
    // Pack world normal: xy = rotated screen-plane components, z = depth component
    out.worldNormal  = float3(rotNrm2D.x, rotNrm2D.y, tiltedNrm.y);
    out.brightness   = leaf.brightness;
    out.opacity      = leaf.opacity;
    return out;
}

fragment float4 leaf3DFragment(
    LeafMeshVertexOut              in          [[stage_in]],
    texture2d_array<float> leafTextures        [[texture(0)]],
    constant float&        timeOfDay           [[buffer(0)]],
    constant uint&         speciesIndex        [[buffer(1)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 tex = leafTextures.sample(s, in.uv, speciesIndex);
    if (tex.a < 0.05f) discard_fragment();

    // Directional lighting using the mesh's real surface normals.
    float3 sunDir = normalize(float3(0.3f, 0.6f, 0.7f));
    float  diffuse = max(0.0f, dot(in.worldNormal, sunDir));
    float  ambient = 0.40f;
    float  light   = ambient + (1.0f - ambient) * diffuse;

    // Back-face: darker with a subtle warm SSS tint (leaf is translucent in real life).
    if (in.worldNormal.z < 0.0f) {
        float backFace = -in.worldNormal.z;
        light = 0.30f + 0.15f * backFace;
        tex.rgb = mix(tex.rgb, float3(0.92f, 0.82f, 0.60f), 0.15f * backFace);
    }

    // Night dimming (match grass & existing leaf dimming).
    float tod = timeOfDay;
    float dayFactor;
    if (tod < 6.0f || tod > 21.0f) {
        dayFactor = 0.15f;
    } else if (tod < 8.0f) {
        dayFactor = 0.15f + 0.85f * ((tod - 6.0f) / 2.0f);
    } else if (tod > 19.0f) {
        dayFactor = 0.15f + 0.85f * ((21.0f - tod) / 2.0f);
    } else {
        dayFactor = 1.0f;
    }

    return float4(tex.rgb * light * in.brightness * dayFactor, tex.a * in.opacity);
}

fragment float4 leaf3DShadowFragment(
    LeafMeshVertexOut              in          [[stage_in]],
    texture2d_array<float> leafTextures        [[texture(0)]],
    constant uint&         speciesIndex        [[buffer(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 tex = leafTextures.sample(s, in.uv, speciesIndex);
    if (tex.a < 0.05f) discard_fragment();

    // Shadow fades as leaf tilts edge-on (worldNormal.z → 0).
    float shadowFade = abs(in.worldNormal.z);
    float alpha = tex.a * 0.28f * shadowFade * in.opacity;
    return float4(0.010f, 0.018f, 0.004f, alpha);
}
