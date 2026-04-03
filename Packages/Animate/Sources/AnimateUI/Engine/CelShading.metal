#include <metal_stdlib>
using namespace metal;
#include <SceneKit/scn_metal>

// MARK: - Cel-Shading Post-Process Shader
//
// Single full-screen pass: colour quantisation (toon bands) + Sobel edge
// detection on depth and colour buffers.  Applied via SCNTechnique DRAW_QUAD.

// --- Data types ---

struct CelVertexIn {
    float4 position [[attribute(SCNVertexSemanticPosition)]];
};

struct CelVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Uniform struct — field ORDER must match the input declaration order in the
// technique dictionary (SCNTechnique packs symbols into buffer(0) in the
// order they appear in the pass "inputs" dictionary).
struct CelUniforms {
    float outlineWidth;
    float colorBands;
    float shadowThreshold;
    float highlightThreshold;
    float outlineR;
    float outlineG;
    float outlineB;
    float outlineA;
};

// --- Vertex shader (full-screen quad passthrough) ---

vertex CelVertexOut cel_vertex(CelVertexIn in [[stage_in]]) {
    CelVertexOut out;
    out.position = in.position;
    // Map clip-space [-1,1] to UV [0,1], flip Y for Metal texture coords.
    out.texCoord = float2((in.position.x + 1.0) * 0.5,
                          1.0 - (in.position.y + 1.0) * 0.5);
    return out;
}

// --- Fragment shader (cel shading + ink outlines) ---

fragment half4 cel_fragment(
    CelVertexOut in                                      [[stage_in]],
    texture2d<float, access::sample> colorSampler        [[texture(0)]],
    texture2d<float, access::sample> depthSampler        [[texture(1)]],
    constant CelUniforms &uniforms                       [[buffer(0)]]
) {
    constexpr sampler smp(coord::normalized,
                          filter::linear,
                          address::clamp_to_edge);

    float4 color = colorSampler.sample(smp, in.texCoord);
    float bands  = max(uniforms.colorBands, 1.0);

    // ---- 1. Colour Quantisation (cel shading) ----
    float lum = dot(color.rgb, float3(0.299, 0.587, 0.114));

    // Push darks and brights toward discrete tones.
    float adjusted = lum;
    if (lum < uniforms.shadowThreshold) {
        adjusted = uniforms.shadowThreshold * 0.5;
    } else if (lum > uniforms.highlightThreshold) {
        adjusted = 1.0;
    }

    float quantized = floor(adjusted * bands + 0.5) / bands;
    float scale     = quantized / max(lum, 0.001);
    float3 celColor = clamp(color.rgb * scale, 0.0, 1.0);

    // ---- 2. Depth-based Sobel edge detection ----
    float2 texel = float2(1.0 / colorSampler.get_width(),
                          1.0 / colorSampler.get_height());
    float2 st = texel * uniforms.outlineWidth;

    float d00 = depthSampler.sample(smp, in.texCoord + float2(-st.x, -st.y)).r;
    float d10 = depthSampler.sample(smp, in.texCoord + float2(  0.0, -st.y)).r;
    float d20 = depthSampler.sample(smp, in.texCoord + float2( st.x, -st.y)).r;
    float d01 = depthSampler.sample(smp, in.texCoord + float2(-st.x,   0.0)).r;
    float d21 = depthSampler.sample(smp, in.texCoord + float2( st.x,   0.0)).r;
    float d02 = depthSampler.sample(smp, in.texCoord + float2(-st.x,  st.y)).r;
    float d12 = depthSampler.sample(smp, in.texCoord + float2(  0.0,  st.y)).r;
    float d22 = depthSampler.sample(smp, in.texCoord + float2( st.x,  st.y)).r;

    float gx = -d00 - 2.0*d01 - d02 + d20 + 2.0*d21 + d22;
    float gy = -d00 - 2.0*d10 - d20 + d02 + 2.0*d12 + d22;
    float depthEdge = smoothstep(0.002, 0.006, sqrt(gx*gx + gy*gy));

    // ---- 3. Colour-contrast edge detection ----
    // Catches surface-detail edges that depth alone misses.
    float3 cL = colorSampler.sample(smp, in.texCoord + float2(-st.x, 0.0)).rgb;
    float3 cR = colorSampler.sample(smp, in.texCoord + float2( st.x, 0.0)).rgb;
    float3 cU = colorSampler.sample(smp, in.texCoord + float2(0.0, -st.y)).rgb;
    float3 cD = colorSampler.sample(smp, in.texCoord + float2(0.0,  st.y)).rgb;
    float colorEdge = smoothstep(0.15, 0.4, length(cR - cL) + length(cD - cU));

    float edge = max(depthEdge, colorEdge);

    // ---- 4. Composite ----
    float4 inkColor = float4(uniforms.outlineR, uniforms.outlineG,
                             uniforms.outlineB, uniforms.outlineA);
    float3 result = mix(celColor, inkColor.rgb, edge * inkColor.a);

    return half4(float4(result, color.a));
}
