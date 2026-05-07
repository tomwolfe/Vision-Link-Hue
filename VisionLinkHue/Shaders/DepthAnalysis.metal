#include <metal_stdlib>
using namespace metal;

kernel void quadrantDepthHistogram(
    texture2d<float> depthTexture [[texture(0)]],
    device float* quadrantCounts [[buffer(1)]],
    constant float& width [[buffer(2)]],
    constant float& height [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 lid [[thread_position_in_threadgroup]],
    uint2 tid [[threadgroup_position_in_grid]],
    uint2 tsize [[threads_per_threadgroup]]
) {
    if (gid.x >= uint(width) || gid.y >= uint(height)) return;
    
    float depthValue = depthTexture.read(gid).r;
    
    float4 localCounts = float4(0.0f);
    if (depthValue >= 0.1f && depthValue <= 10.0f) {
        int quadrant;
        if (gid.x < uint(width) / 2) {
            quadrant = (gid.y < uint(height) / 2) ? 0 : 2;
        } else {
            quadrant = (gid.y < uint(height) / 2) ? 1 : 3;
        }
        localCounts[quadrant] = 1.0f;
    }
    
    float4 groupReduction = simd_sum(localCounts);
    
    if (lid.x == 0 && lid.y == 0) {
        for (int i = 0; i < 4; i++) {
            quadrantCounts[i] += groupReduction[i];
        }
    }
}
