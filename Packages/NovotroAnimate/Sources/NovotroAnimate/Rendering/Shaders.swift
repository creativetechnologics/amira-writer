import simd

// MARK: - GPU Shared Types

/// Uniforms shared between CPU and GPU.
struct CanvasUniforms {
    var projectionMatrix: simd_float4x4
    var viewMatrix: simd_float4x4
}

/// A single textured sprite instance for the canvas renderer.
struct SpriteInstance {
    var position: SIMD2<Float>     // center position in canvas coords
    var size: SIMD2<Float>         // width, height
    var rotation: Float            // radians
    var opacity: Float             // 0-1
    var uvOrigin: SIMD2<Float>     // texture coordinate origin
    var uvSize: SIMD2<Float>       // texture coordinate size
    var zOrder: Float              // depth sorting
    var color: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
}

/// Uniforms for the timeline renderer (viewport + scroll).
struct TimelineUniforms {
    var viewportSize: SIMD2<Float>
    var scrollOffset: SIMD2<Float>
}

/// A colored rectangle instance for timeline rendering.
struct RectInstance {
    var position: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
    var cornerRadius: Float
    var _padding: Float = 0
}

// MARK: - Canvas Shader Source (textured sprites)

let canvasShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct CanvasUniforms {
    float4x4 projectionMatrix;
    float4x4 viewMatrix;
};

struct SpriteInstance {
    float2 position;
    float2 size;
    float rotation;
    float opacity;
    float2 uvOrigin;
    float2 uvSize;
    float zOrder;
    float4 color;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float opacity;
    float4 color;
};

vertex VertexOut sprite_vertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant CanvasUniforms &uniforms [[buffer(0)]],
    constant SpriteInstance *instances [[buffer(1)]]
) {
    // Unit quad: 6 vertices for 2 triangles
    const float2 positions[6] = {
        float2(-0.5, -0.5), float2(0.5, -0.5), float2(-0.5, 0.5),
        float2(0.5, -0.5),  float2(0.5,  0.5), float2(-0.5, 0.5)
    };
    const float2 uvs[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };

    SpriteInstance inst = instances[instanceID];
    float2 unitPos = positions[vertexID];

    // Apply scale
    float2 scaled = unitPos * inst.size;

    // Apply rotation
    float cosR = cos(inst.rotation);
    float sinR = sin(inst.rotation);
    float2 rotated = float2(
        scaled.x * cosR - scaled.y * sinR,
        scaled.x * sinR + scaled.y * cosR
    );

    // Translate to world position
    float4 worldPos = float4(rotated + inst.position, inst.zOrder, 1.0);

    VertexOut out;
    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;
    out.texCoord = inst.uvOrigin + uvs[vertexID] * inst.uvSize;
    out.opacity = inst.opacity;
    out.color = inst.color;
    return out;
}

fragment float4 sprite_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler samp [[sampler(0)]]
) {
    float4 color = tex.sample(samp, in.texCoord);
    color *= in.color;
    color.a *= in.opacity;
    // Premultiply alpha (lesson 15.1)
    color.rgb *= color.a;
    return color;
}

// Flat color sprite (no texture) for placeholder rendering
fragment float4 sprite_flat_fragment(
    VertexOut in [[stage_in]]
) {
    float alpha = 0.3 * in.opacity * in.color.a;
    return float4(in.color.rgb * alpha, alpha);
}
"""

// MARK: - Timeline Shader Source (instanced rects)

let timelineShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct TimelineUniforms {
    float2 viewportSize;
    float2 scrollOffset;
};

struct RectInstance {
    float2 position;
    float2 size;
    float4 color;
    float cornerRadius;
    float _padding;
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
    float2 rectPos;
    float2 rectSize;
    float cornerRadius;
};

vertex VertexOut timeline_vertex_rect(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant TimelineUniforms &uniforms [[buffer(0)]],
    constant RectInstance *instances [[buffer(1)]]
) {
    const float2 positions[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };

    float2 unitPos = positions[vertexID];
    RectInstance inst = instances[instanceID];

    float2 pointPos = inst.position - uniforms.scrollOffset + unitPos * inst.size;

    float2 ndc;
    ndc.x = (pointPos.x / uniforms.viewportSize.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (pointPos.y / uniforms.viewportSize.y) * 2.0;

    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = inst.color;
    out.rectPos = unitPos * inst.size;
    out.rectSize = inst.size;
    out.cornerRadius = inst.cornerRadius;
    return out;
}

fragment float4 timeline_fragment_rect(VertexOut in [[stage_in]]) {
    if (in.cornerRadius > 0.001) {
        float2 halfSize = in.rectSize * 0.5;
        float2 center = in.rectPos - halfSize;
        float2 q = abs(center) - halfSize + in.cornerRadius;
        float dist = min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - in.cornerRadius;
        if (dist > 0.5) {
            discard_fragment();
        }
        float alpha = in.color.a * saturate(0.5 - dist);
        return float4(in.color.rgb * alpha, alpha);
    }
    return in.color;
}
"""

// MARK: - Matrix Helpers

func orthographicProjection(width: Float, height: Float) -> simd_float4x4 {
    // Maps (0,0)-(width,height) to NDC (-1,-1)-(1,1), Y-down
    let sx: Float = 2.0 / width
    let sy: Float = -2.0 / height
    return simd_float4x4(columns: (
        SIMD4<Float>(sx,  0,  0, 0),
        SIMD4<Float>( 0, sy,  0, 0),
        SIMD4<Float>( 0,  0,  1, 0),
        SIMD4<Float>(-1,  1,  0, 1)
    ))
}

func translationMatrix(x: Float, y: Float) -> simd_float4x4 {
    simd_float4x4(columns: (
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(x, y, 0, 1)
    ))
}

func scaleMatrix(sx: Float, sy: Float) -> simd_float4x4 {
    simd_float4x4(columns: (
        SIMD4<Float>(sx, 0,  0, 0),
        SIMD4<Float>(0,  sy, 0, 0),
        SIMD4<Float>(0,  0,  1, 0),
        SIMD4<Float>(0,  0,  0, 1)
    ))
}
