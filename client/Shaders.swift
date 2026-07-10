import Foundation

// Compiled at runtime via device.makeLibrary(source:), which avoids SwiftPM's
// metallib-bundling quirks entirely. All buffer/texture indices below must stay
// in sync with Renderer.swift.
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Params {
    uint   count;
    float  dt;
    float  speed;
    uint   frame;
    float2 aspect;      // clip-space scale keeping the [-1,1] domain square
    float  pointSize;
    float  lifeMin;
    float  lifeMax;
    float  fade;        // per-frame trail decay (used by the fade pass)
    float  alpha;       // temporal blend between the two most recent field frames
};

// --- cheap integer hash -> [0,1) -------------------------------------------
inline float hash11(uint n) {
    n = (n ^ 61u) ^ (n >> 16);
    n *= 9u;
    n = n ^ (n >> 4);
    n *= 0x27d4eb2du;
    n = n ^ (n >> 15);
    return float(n & 0x00FFFFFFu) / float(0x01000000);
}
inline float2 hash21(uint n) {
    return float2(hash11(n), hash11(n * 747796405u + 2891336453u));
}

constexpr sampler fieldSampler(coord::normalized, address::clamp_to_edge, filter::linear);

// --- advection: move every particle through the (time-interpolated) field ---
kernel void advect(device float2*      pos       [[buffer(0)]],
                   device float*       life      [[buffer(1)]],
                   device float*       spd       [[buffer(2)]],
                   constant Params&    P         [[buffer(3)]],
                   texture2d<float>    fieldPrev [[texture(0)]],
                   texture2d<float>    fieldCurr [[texture(1)]],
                   uint id [[thread_position_in_grid]])
{
    if (id >= P.count) return;

    float2 x  = pos[id];
    float2 uv = x * 0.5 + 0.5;                       // [-1,1] -> [0,1]
    float2 vp = fieldPrev.sample(fieldSampler, uv).xy;
    float2 vc = fieldCurr.sample(fieldSampler, uv).xy;
    float2 v  = mix(vp, vc, P.alpha);                // smooth between 30 Hz frames

    x += v * (P.dt * P.speed);
    float l = life[id] - P.dt;

    bool outside = (x.x < -1.05 || x.x > 1.05 || x.y < -1.05 || x.y > 1.05);
    if (l <= 0.0 || outside) {
        uint seed = id * 2654435761u ^ (P.frame * 40503u);
        x = hash21(seed) * 2.0 - 1.0;
        l = P.lifeMin + hash11(seed ^ 0x9e3779b9u) * (P.lifeMax - P.lifeMin);
    }

    pos[id]  = x;
    life[id] = l;
    spd[id]  = length(v);
}

// --- particle points --------------------------------------------------------
struct PointOut {
    float4 position [[position]];
    float  psize    [[point_size]];
    float3 color;
};

inline float3 ramp(float t) {
    t = clamp(t, 0.0, 1.0);
    float3 a = float3(0.06, 0.02, 0.20);   // deep indigo
    float3 b = float3(0.10, 0.55, 0.90);   // cyan
    float3 c = float3(1.00, 0.80, 0.35);   // warm gold
    return (t < 0.5) ? mix(a, b, smoothstep(0.0, 0.5, t))
                     : mix(b, c, smoothstep(0.5, 1.0, t));
}

vertex PointOut point_vertex(uint vid [[vertex_id]],
                             device const float2* pos  [[buffer(0)]],
                             device const float*  life [[buffer(1)]],
                             device const float*  spd  [[buffer(2)]],
                             constant Params&     P    [[buffer(3)]])
{
    PointOut o;
    float2 x   = pos[vid];
    o.position = float4(x * P.aspect, 0.0, 1.0);
    o.psize    = P.pointSize;
    float s    = clamp(spd[vid] * 0.5, 0.0, 1.0);
    o.color    = ramp(s) * 0.9;
    return o;
}

fragment float4 point_fragment(PointOut in [[stage_in]],
                               float2 pc [[point_coord]])
{
    float d = length(pc - 0.5);
    float a = smoothstep(0.5, 0.0, d);      // soft round sprite
    return float4(in.color * a, a);          // premultiplied, additive
}

// --- vortex markers (the "motor" of the flow) -------------------------------
struct MarkerOut {
    float4 position [[position]];
    float  psize    [[point_size]];
    float3 color;
    float  glow;
};

vertex MarkerOut marker_vertex(uint vid [[vertex_id]],
                               device const float* vort [[buffer(0)]],  // packed x,y,gamma
                               constant Params&    P    [[buffer(1)]])
{
    float x = vort[3 * vid + 0];
    float y = vort[3 * vid + 1];
    float g = vort[3 * vid + 2];

    MarkerOut o;
    o.position = float4(float2(x, y) * P.aspect, 0.0, 1.0);
    float mag  = fabs(g);
    o.psize    = 10.0 + mag * 12.0;
    // warm = counter-clockwise (+), cool = clockwise (-)
    float3 warm = float3(1.00, 0.45, 0.15);
    float3 cool = float3(0.25, 0.60, 1.00);
    o.color = (g >= 0.0) ? warm : cool;
    o.glow  = clamp(mag, 0.0, 1.5);
    return o;
}

fragment float4 marker_fragment(MarkerOut in [[stage_in]], float2 pc [[point_coord]])
{
    float d    = length(pc - 0.5) * 2.0;          // 0 centre .. 1 edge
    float core = smoothstep(0.30, 0.0, d);
    float halo = smoothstep(1.0, 0.30, d) * 0.45;
    float a    = core + halo;
    return float4(in.color * (0.5 + in.glow) * a, a);
}

// --- fullscreen triangle ----------------------------------------------------
struct FSOut { float4 position [[position]]; float2 uv; };

vertex FSOut fs_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    FSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

fragment float4 fade_fragment(FSOut in [[stage_in]], constant Params& P [[buffer(0)]]) {
    return float4(0.0, 0.0, 0.0, P.fade);
}

fragment float4 present_fragment(FSOut in [[stage_in]],
                                 texture2d<float> trail [[texture(0)]])
{
    constexpr sampler s(coord::normalized, filter::linear);
    float3 c = trail.sample(s, in.uv).rgb;
    c = c / (c + 1.0);                 // Reinhard
    c = pow(c, float3(1.0 / 2.2));     // gamma
    return float4(c, 1.0);
}
"""
