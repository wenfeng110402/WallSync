#include <metal_stdlib>
#include <simd/simd.h>
using namespace metal;

// MARK: - 顶点与纹理坐标结构
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// MARK: - 全屏四边形顶点着色器
vertex VertexOut vertex_main(uint vertexID [[vertex_id]]) {
    // 全屏四边形: 两个三角形 (6 顶点)
    float4 positions[] = {
        float4(-1.0, -1.0, 0.0, 1.0),
        float4( 1.0, -1.0, 0.0, 1.0),
        float4(-1.0,  1.0, 0.0, 1.0),
        float4( 1.0, -1.0, 0.0, 1.0),
        float4(-1.0,  1.0, 0.0, 1.0),
        float4( 1.0,  1.0, 0.0, 1.0),
    };

    float2 texCoords[] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0),
    };

    VertexOut out;
    out.position = positions[vertexID];
    out.texCoord = texCoords[vertexID];
    return out;
}

// MARK: - 区域裁剪顶点着色器
// 传入区域归一化 UV 矩形 (offsetX, offsetY, scaleX, scaleY)
struct RegionUniforms {
    float offsetX;
    float offsetY;
    float scaleX;
    float scaleY;
};

vertex VertexOut vertex_cropped(uint vertexID [[vertex_id]],
                                constant RegionUniforms &uniforms [[buffer(0)]]) {
    float4 positions[] = {
        float4(-1.0, -1.0, 0.0, 1.0),
        float4( 1.0, -1.0, 0.0, 1.0),
        float4(-1.0,  1.0, 0.0, 1.0),
        float4( 1.0, -1.0, 0.0, 1.0),
        float4(-1.0,  1.0, 0.0, 1.0),
        float4( 1.0,  1.0, 0.0, 1.0),
    };

    // 默认全屏纹理坐标
    float2 defaultTexCoords[] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0),
    };

    VertexOut out;
    out.position = positions[vertexID];

    // 根据区域裁剪 UV 坐标
    float2 tc = defaultTexCoords[vertexID];
    tc.x = uniforms.offsetX + tc.x * uniforms.scaleX;
    tc.y = uniforms.offsetY + tc.y * uniforms.scaleY;
    out.texCoord = tc;

    return out;
}

// MARK: - 片元着色器（BGRA 像素缓冲）
fragment float4 fragment_main(VertexOut in [[stage_in]],
                              texture2d<float> videoTexture [[texture(0)]]) {
    constexpr sampler linearSampler(mag_filter::linear,
                                    min_filter::linear,
                                    address::clamp_to_edge);

    float4 color = videoTexture.sample(linearSampler, in.texCoord);

    // BGRA -> RGBA: Metal 默认 BGRA，交换通道
    return float4(color.b, color.g, color.r, color.a);
}
