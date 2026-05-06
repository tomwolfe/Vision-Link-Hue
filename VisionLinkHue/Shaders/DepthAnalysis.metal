#include <metal_stdlib>
using namespace metal;

kernel void quadrantDepthHistogram(
    texture2d<float> depthTexture [[texture(0)]],
    device float* quadrantCounts [[buffer(1)]],
    constant float32& width [[buffer(2)]],
    constant float32& height [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(width) || gid.y >= uint(height)) return;
    
    float depthValue = depthTexture.read(gid).r;
    
    if (depthValue < 0.1 || depthValue > 10.0) return;
    
    int quadrant;
    if (gid.x < uint(width) / 2) {
        quadrant = (gid.y < uint(height) / 2) ? 0 : 2;
    } else {
        quadrant = (gid.y < uint(height) / 2) ? 1 : 3;
    }
    
    atomic_add(&quadrantCounts[quadrant], 1.0f);
}
