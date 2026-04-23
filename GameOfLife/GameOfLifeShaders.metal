#include <metal_stdlib>
using namespace metal;

// Conway's Game of Life on a toroidal (wrap-around) grid.
//
// Cell state: A_t(x,y) in {0,1}
// Neighbor count:
// N_t(x,y) = sum_{dx=-1..1} sum_{dy=-1..1} A_t(x+dx, y+dy) - A_t(x,y)
// Update rule:
// A_{t+1}(x,y) = 1 if (N_t == 3) or (A_t == 1 and N_t == 2), else 0.
// Wrap-around addressing:
// x' = (x + dx + W) % W, y' = (y + dy + H) % H

struct RasterizerData {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle-list quad for rendering the simulation texture.
vertex RasterizerData lifeVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[6] = {
        float2(-1.0, -1.0),
        float2(1.0, -1.0),
        float2(-1.0, 1.0),
        float2(-1.0, 1.0),
        float2(1.0, -1.0),
        float2(1.0, 1.0)
    };

    constexpr float2 uvs[6] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(0.0, 0.0),
        float2(1.0, 1.0),
        float2(1.0, 0.0)
    };

    RasterizerData outData;
    outData.position = float4(positions[vertexID], 0.0, 1.0);
    outData.uv = uvs[vertexID];
    return outData;
}

// Visualize state texture: alive cells are bright, dead cells use dark gradient.
fragment float4 lifeFragment(RasterizerData in [[stage_in]],
                             texture2d<float> stateTexture [[texture(0)]]) {
    constexpr sampler textureSampler(
        mag_filter::nearest,
        min_filter::nearest,
        mip_filter::none,
        address::repeat
    );

    float alive = stateTexture.sample(textureSampler, in.uv).r;

    float3 deadColorA = float3(0.03, 0.05, 0.09);
    float3 deadColorB = float3(0.08, 0.10, 0.14);
    float shade = fract((in.uv.x + in.uv.y) * 96.0);
    float3 deadColor = mix(deadColorA, deadColorB, shade);
    float3 liveColor = float3(0.99, 0.89, 0.27);

    return float4(mix(deadColor, liveColor, alive), 1.0);
}

// Initializes each cell with pseudo-random alive/dead state.
// The threshold controls initial density (0.32 = 32% alive on average).
kernel void seedRandom(texture2d<float, access::write> outState [[texture(0)]],
                       constant uint &seed [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    uint width = outState.get_width();
    uint height = outState.get_height();

    if (gid.x >= width || gid.y >= height) {
        return;
    }

    uint n = gid.x * 1973u + gid.y * 9277u + seed * 26699u;
    n = (n << 13u) ^ n;
    uint rnd = (n * (n * n * 15731u + 789221u) + 1376312589u);

    float random01 = float((rnd >> 8u) & 1023u) / 1023.0;
    float alive = random01 < 0.32 ? 1.0 : 0.0;
    outState.write(float4(alive, alive, alive, 1.0), gid);
}

// Sets the world to all-dead state.
kernel void clearState(texture2d<float, access::write> outState [[texture(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    uint width = outState.get_width();
    uint height = outState.get_height();

    if (gid.x >= width || gid.y >= height) {
        return;
    }

    outState.write(float4(0.0, 0.0, 0.0, 1.0), gid);
}

// Computes one generation using the classic Conway transition rule.
kernel void stepLife(texture2d<float, access::read> current [[texture(0)]],
                     texture2d<float, access::write> next [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
    uint width = current.get_width();
    uint height = current.get_height();

    if (gid.x >= width || gid.y >= height) {
        return;
    }

    uint livingNeighbors = 0u;

    for (int offsetY = -1; offsetY <= 1; ++offsetY) {
        for (int offsetX = -1; offsetX <= 1; ++offsetX) {
            if (offsetX == 0 && offsetY == 0) {
                continue;
            }

            int sampleX = int(gid.x) + offsetX;
            int sampleY = int(gid.y) + offsetY;

            if (sampleX < 0) {
                sampleX += int(width);
            } else if (sampleX >= int(width)) {
                sampleX -= int(width);
            }

            if (sampleY < 0) {
                sampleY += int(height);
            } else if (sampleY >= int(height)) {
                sampleY -= int(height);
            }

            float neighbor = current.read(uint2(uint(sampleX), uint(sampleY))).r;
            livingNeighbors += neighbor > 0.5 ? 1u : 0u;
        }
    }

    bool currentlyAlive = current.read(gid).r > 0.5;
    bool nextAlive = currentlyAlive
        ? (livingNeighbors == 2u || livingNeighbors == 3u)
        : (livingNeighbors == 3u);

    float aliveValue = nextAlive ? 1.0 : 0.0;
    next.write(float4(aliveValue, aliveValue, aliveValue, 1.0), gid);
}
