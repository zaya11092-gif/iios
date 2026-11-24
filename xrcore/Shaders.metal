#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Uniform blocks — layouts must mirror the Swift structs in Compositor.swift.
// NOTE: no float3x3 in constant buffers (Metal aligns it differently than
// Swift simd); the reproj matrix travels as three float4 rows instead.
// ---------------------------------------------------------------------------

struct BackgroundUniforms {
    float2 uvScale;      // cover-fit scale from screen uv -> buffer uv
    float2 uvOffset;
    float flipH;
    float flipV;
    float brightness;
    float darkMode;      // 1 = VR mode / no camera frame: draw dim background
};

struct ItemUniforms {
    float4x4 mvp;
    float4x4 model;
};

struct ItemFragUniforms {
    float4 color;
    float4 lightDir;
    float4 eyePos;
};

struct DistortionUniforms {
    float4 reproj0;
    float4 reproj1;
    float4 reproj2;
    float2 tanHalf;      // (tan(fovX/2), tan(fovX/2)/aspect)
    float2 k1k2;         // barrel compensation coefficients
    float2 grid;         // (cols, rows) per eye
    float  timewarpOn;
};

// ---------------------------------------------------------------------------
// Background (monoscopic passthrough or dark VR backdrop)
// ---------------------------------------------------------------------------

struct BgOut {
    float4 pos [[position]];
    float2 uv;
};

vertex BgOut bgVertex(uint vid [[vertex_id]]) {
    const float2 corners[6] = { {0,0}, {1,0}, {0,1}, {1,0}, {1,1}, {0,1} };
    float2 c = corners[vid % 6];
    BgOut o;
    o.pos = float4(c * 2.0 - 1.0, 0.0, 1.0);
    o.uv = c;
    return o;
}

fragment float4 bgFragment(BgOut in [[stage_in]],
                           texture2d<float> luma   [[texture(0)]],
                           texture2d<float> chroma [[texture(1)]],
                           constant BackgroundUniforms &u   [[buffer(0)]],
                           constant float2 *joints          [[buffer(1)]],
                           constant uint   &jointCount      [[buffer(2)]],
                           constant float  &jointsActive    [[buffer(3)]]) {
    float2 suv = u.uvOffset + in.uv * u.uvScale;
    if (u.flipH > 0.5) { suv.x = 1.0 - suv.x; }
    if (u.flipV > 0.5) { suv.y = 1.0 - suv.y; }

    float3 rgb;
    if (u.darkMode > 0.5) {
        rgb = float3(0.02, 0.02, 0.045);
    } else {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float y  = luma.sample(s, suv).r;
        float2 c = chroma.sample(s, suv).rg;
        // BT.601 video-range YCbCr (ARKit capturedImage) -> RGB.
        const float3x3 m = float3x3(
            float3(1.164, 1.164, 1.164),
            float3(0.000, -0.391, 2.018),
            float3(1.596, -0.813, 0.000));
        float3 yuv = float3(y, c.x, c.y) - float3(0.0625, 0.5, 0.5);
        rgb = clamp(m * yuv, 0.0, 1.0);
    }
    rgb *= u.brightness;

    // Debug overlay: green dots on tracked hand joints (buffer-space coords).
    if (jointsActive > 0.5) {
        const float2 aspectFix = float2(1.333, 1.0); // buffer is 4:3
        for (uint i = 0; i < jointCount && i < 42; i++) {
            float d = length((suv - joints[i]) * aspectFix);
            float m = smoothstep(0.012, 0.005, d);
            rgb = mix(rgb, float3(0.2, 1.0, 0.2), m);
        }
    }
    return float4(rgb, 1.0);
}

// ---------------------------------------------------------------------------
// Scene items (lit primitives)
// ---------------------------------------------------------------------------

struct SceneVertexOut {
    float4 pos [[position]];
    float3 normal;
    float3 worldPos;
};

// NOTE: attribute buffers must use float3, not packed_float3 — the vertex
// descriptor (float3 @0, float3 @12, stride 24) makes Metal fetch the packed
// interleaved layout correctly.
vertex SceneVertexOut sceneVertex(const device float3 *positions [[attribute(0)]],
                                  const device float3 *normals   [[attribute(1)]],
                                  uint vid [[vertex_id]],
                                  constant ItemUniforms &u [[buffer(1)]]) {
    float3 p = float3(positions[vid]);
    float3 n = float3(normals[vid]);
    SceneVertexOut o;
    float4 wp = u.model * float4(p, 1.0);
    o.worldPos = wp.xyz;
    o.normal = normalize((u.model * float4(n, 0.0)).xyz);
    o.pos = u.mvp * float4(p, 1.0);
    return o;
}

fragment float4 sceneFragment(SceneVertexOut in [[stage_in]],
                              constant ItemFragUniforms &f [[buffer(0)]]) {
    float3 n = normalize(in.normal);
    float ndl = max(dot(n, normalize(f.lightDir.xyz)), 0.0);
    float hemi = 0.35 + 0.3 * clamp(n.y * 0.5 + 0.5, 0.0, 1.0);
    float3 c = f.color.rgb * (0.25 + 0.55 * ndl + 0.25 * hemi);
    return float4(c, f.color.a);
}

// ---------------------------------------------------------------------------
// Final pass: per-eye lens distortion + rotational timewarp.
// The grid is generated procedurally from vertex_id (no buffers).
// ---------------------------------------------------------------------------

struct DOut {
    float4 pos [[position]];
    float2 uv;
    float  eye;
};

vertex DOut distortVertex(uint vid [[vertex_id]],
                          constant DistortionUniforms &u [[buffer(0)]]) {
    uint quadsPerEye = uint(u.grid.x) * uint(u.grid.y);
    uint eye  = vid / (quadsPerEye * 6);
    uint quad = (vid % (quadsPerEye * 6)) / 6;
    uint corner = vid % 6;

    const float2 ct[6] = { {0,0}, {1,0}, {0,1}, {1,0}, {1,1}, {0,1} };
    float2 cell = float2(quad % uint(u.grid.x), quad / uint(u.grid.x));
    float2 local = (cell + ct[corner]) / u.grid;
    float2 cl = local * 2.0 - 1.0;

    // Screen ray in eye space, reprojected render->predicted rotation.
    float3 ray = normalize(float3(cl.x * u.tanHalf.x, cl.y * u.tanHalf.y, -1.0));
    float3 wr = ray;
    if (u.timewarpOn > 0.5) {
        float3x3 rp = float3x3(u.reproj0.xyz, u.reproj1.xyz, u.reproj2.xyz);
        wr = rp * ray;
    }
    float2 w = wr.xy / max(-wr.z, 1e-4);
    w /= u.tanHalf;

    // Barrel compensation for the (user-tunable) lens profile.
    float r2 = dot(w, w);
    float2 d = w * (1.0 + u.k1k2.x * r2 + u.k1k2.y * r2 * r2);

    DOut o;
    o.uv = 0.5 + 0.5 * d;
    o.eye = float(eye);
    float clipX = local.x - (eye == 0 ? 1.0 : 0.0);
    o.pos = float4(clipX, local.y * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

fragment float4 distortFragment(DOut in [[stage_in]],
                                texture2d<float> texL [[texture(0)]],
                                texture2d<float> texR [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = (in.eye < 0.5) ? texL.sample(s, in.uv).rgb : texR.sample(s, in.uv).rgb;
    return float4(c, 1.0);
}
